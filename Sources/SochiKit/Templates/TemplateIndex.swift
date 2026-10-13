import Foundation

/// One `.xctemplate` from the selected Xcode (or the user's own templates).
public struct XcodeTemplate: @unchecked Sendable {
    public let identifier: String
    /// Folder name without extension, e.g. "Widget Extension".
    public let name: String
    /// Parent folder, e.g. "Application Extension".
    public let category: String
    /// Platform folder, e.g. "iOS" or "MultiPlatform".
    public let platformFolder: String
    let directory: URL
    let info: [String: Any]

    /// Command-line name: "Widget Extension" → `widget-extension`.
    public var slug: String {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    /// The slug as seen from a platform: templates of another platform are prefixed, e.g. `watchos-app`.
    public func slug(from platformFolder: String) -> String {
        [platformFolder, "MultiPlatform"].contains(self.platformFolder) ? slug : "\(self.platformFolder.lowercased())-\(slug)"
    }
}

/// Xcode's project/target templates, discovered at runtime. sochi ships none of its own.
///
/// The format (TemplateInfo.plist) is Apple-private and undocumented, so parsing is lenient: unknown keys are
/// ignored, and anything sochi can't interpret is reported as unsupported rather than approximated.
public struct TemplateIndex: @unchecked Sendable {
    let templates: [String: XcodeTemplate]

    public static func load() async throws -> TemplateIndex {
        let developer = URL(fileURLWithPath: try await Shell.run(["xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines))
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/Templates/Project Templates"),
            developer.appendingPathComponent("Platforms/iPhoneOS.platform/Developer/Library/Xcode/Templates/Project Templates"),
            developer.appendingPathComponent("Platforms/WatchOS.platform/Developer/Library/Xcode/Templates/Project Templates"),
            developer.appendingPathComponent("Library/Xcode/Templates/Project Templates"),
        ]
        let index = load(roots: roots)
        guard !index.templates.isEmpty else { throw SochiError.xcodeDataUnavailable("project templates") }
        return index
    }

    static func load(roots: [URL]) -> TemplateIndex {
        var templates: [String: XcodeTemplate] = [:]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "xctemplate" {
                walker.skipDescendants()
                guard let data = try? Data(contentsOf: url.appendingPathComponent("TemplateInfo.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = info["Identifier"] as? String, templates[identifier] == nil
                else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "").split(separator: "/").map(String.init)
                templates[identifier] = XcodeTemplate(
                    identifier: identifier,
                    name: url.deletingPathExtension().lastPathComponent,
                    category: relative.count >= 2 ? relative[relative.count - 2] : "",
                    platformFolder: relative.first ?? "",
                    directory: url, info: info)
            }
        }
        return TemplateIndex(templates: templates)
    }

    /// Concrete templates that create a target for a platform, sorted by category and name. Includes templates of
    /// other platforms that the platform's apps can host (e.g. a watchOS app inside an iOS app).
    public func targetTemplates(platformFolder: String = "iOS") -> [XcodeTemplate] {
        let platformID = ["iOS": "com.apple.platform.iphoneos", "watchOS": "com.apple.platform.watchos"][platformFolder]
        return templates.values
            .filter { $0.info["Concrete"] as? Bool == true && $0.info["Kind"] as? String == "Xcode.Xcode3.ProjectTemplateUnitKind" }
            .filter { t in
                if [platformFolder, "MultiPlatform"].contains(t.platformFolder) { return true }
                let allowed = resolve(t).association?["AllowablePlatforms"] as? [String] ?? []
                return platformID.map(allowed.contains) ?? false
            }
            .filter { createsTarget(resolve($0)) }
            .sorted { ($0.category, $0.name, $0.platformFolder) < ($1.category, $1.name, $1.platformFolder) }
    }

    /// Whether a template creates a target itself or through components (possibly selected by an option).
    func createsTarget(_ resolved: ResolvedTemplate) -> Bool {
        resolved.targets.first?["ProductType"] is String || !resolved.components.isEmpty
            || resolved.units.values.contains { $0.values.contains { $0.contains { $0.unit["Components"] != nil } } }
    }

    /// Finds a template by slug, display name, or identifier, then by unambiguous partial name.
    /// Platform-specific templates win over MultiPlatform ones of the same name.
    public func find(_ query: String, platformFolder: String = "iOS") throws -> XcodeTemplate {
        let pool = targetTemplates(platformFolder: platformFolder)
        let q = query.lowercased()
        let exact = pool.filter { $0.slug(from: platformFolder) == q || $0.identifier.lowercased() == q
            || ($0.name.lowercased() == q && [platformFolder, "MultiPlatform"].contains($0.platformFolder)) }
        if let best = exact.first(where: { $0.platformFolder == platformFolder }) ?? exact.first { return best }
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var partial = pool.filter { t in words.allSatisfy { t.slug(from: platformFolder).contains($0) } }
        // Drop MultiPlatform duplicates of platform templates with the same name.
        partial = partial.filter { t in t.platformFolder == platformFolder || !partial.contains { $0.name == t.name && $0.platformFolder == platformFolder } }
        // Same-named templates of other platforms (e.g. watchOS Widget Extension) lose to the requested platform's.
        if partial.contains(where: { $0.platformFolder == platformFolder }) {
            partial = partial.filter { t in t.platformFolder == platformFolder || !partial.contains { $0.platformFolder == platformFolder && $0.name == t.name } }
        }
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty { throw SochiError.unknownTemplate(query) }
        throw SochiError.ambiguousTemplate(query, candidates: partial.map { $0.slug(from: platformFolder) })
    }

    /// The template and its ancestors, nearest first (depth-first, as listed in `Ancestors`).
    func chain(_ template: XcodeTemplate) -> [XcodeTemplate] {
        var result: [XcodeTemplate] = []
        func visit(_ id: String) {
            guard let t = templates[id], !result.contains(where: { $0.identifier == id }) else { return }
            result.append(t)
            for ancestor in t.info["Ancestors"] as? [String] ?? [] { visit(ancestor) }
        }
        visit(template.identifier)
        return result
    }

    /// Merges a template with its ancestors. Nearer templates win; settings merge key by key.
    func resolve(_ template: XcodeTemplate) -> ResolvedTemplate {
        var resolved = ResolvedTemplate(template: template)
        for t in chain(template).reversed() { resolved.merge(t.info, from: t.directory) }
        resolved.association = template.info["AssociatedTargetSpecification"] as? [String: Any]
            ?? chain(template).lazy.compactMap { $0.info["AssociatedTargetSpecification"] as? [String: Any] }.first
        return resolved
    }
}

/// A template merged with its ancestors (and, later, with the units its options select).
struct ResolvedTemplate {
    struct Definition {
        let value: Any
        /// Directory of the template that defined it, where its `Path` is relative to.
        let directory: URL
    }

    let template: XcodeTemplate
    var definitions: [String: Definition] = [:]
    var nodes: [String] = []
    var options: [[String: Any]] = []
    var targets: [[String: Any]] = []
    var project: [String: Any] = [:]
    var constraints: [[String: Any]] = []
    var components: [Any] = []
    var association: [String: Any]?
    /// Option units accumulated across the whole chain (option → value → units), each with the directory of the
    /// template that declared it: nearer templates add units for an option rather than replacing an ancestor's.
    var units: [String: [String: [(unit: [String: Any], directory: URL)]]] = [:]

    init(template: XcodeTemplate) { self.template = template }

    mutating func merge(_ info: [String: Any], from directory: URL) {
        for (key, value) in info["Definitions"] as? [String: Any] ?? [:] {
            definitions[key] = Definition(value: value, directory: directory)
        }
        for node in info["Nodes"] as? [String] ?? [] where !nodes.contains(node) { nodes.append(node) }
        for option in info["Options"] as? [[String: Any]] ?? [] {
            if let id = option["Identifier"] as? String {
                for (value, unit) in option["Units"] as? [String: Any] ?? [:] {
                    let list = (unit as? [[String: Any]]) ?? [(unit as? [String: Any]) ?? [:]]
                    units[id, default: [:]][value, default: []] += list.map { ($0, directory) }
                }
            }
            if let id = option["Identifier"] as? String, let index = options.firstIndex(where: { $0["Identifier"] as? String == id }) {
                options[index].merge(option) { $1 }
            } else {
                options.append(option)
            }
        }
        for (index, target) in (info["Targets"] as? [[String: Any]] ?? []).enumerated() {
            if index < targets.count { targets[index] = Self.mergeTarget(targets[index], target) } else { targets.append(target) }
        }
        if let project = info["Project"] as? [String: Any] { self.project = Self.mergeTarget(self.project, project) }
        constraints += info["OptionConstraints"] as? [[String: Any]] ?? []
        components += info["Components"] as? [Any] ?? []
    }

    /// Settings merge key by key (per configuration too); frameworks accumulate; anything else is replaced.
    static func mergeTarget(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            switch key {
            case "SharedSettings":
                result[key] = (base[key] as? [String: Any] ?? [:]).merging(value as? [String: Any] ?? [:]) { $1 }
            case "Configurations":
                var configs = base[key] as? [String: [String: Any]] ?? [:]
                for (name, settings) in value as? [String: [String: Any]] ?? [:] {
                    configs[name] = (configs[name] ?? [:]).merging(settings) { $1 }
                }
                result[key] = configs
            case "Frameworks":
                let existing = base[key] as? [String] ?? []
                result[key] = existing + (value as? [String] ?? []).filter { !existing.contains($0) }
            default:
                result[key] = value
            }
        }
        return result
    }
}
