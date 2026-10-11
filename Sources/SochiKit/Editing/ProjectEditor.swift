import Foundation

/// A set of file changes, computed up front so it can be shown, dry-run, applied, and rolled back as a unit.
public struct EditPlan: Sendable {
    public struct FileEdit: Sendable {
        public let url: URL
        /// nil when the file is being created.
        public let original: Data?
        public let updated: Data
    }

    public let target: String
    public let projectURL: URL
    public internal(set) var edits: [FileEdit] = []
    public internal(set) var notes: [String] = []
    /// Configuration name → the `CODE_SIGN_ENTITLEMENTS` xcodebuild must resolve to after applying.
    var expectedEntitlements: [String: String] = [:]
}

/// Edits capabilities the way Xcode's "+ Capability" does, but only touching local files:
/// the entitlements plist, and `CODE_SIGN_ENTITLEMENTS` when the target has no entitlements file yet.
///
/// Safety rules:
/// - Where a target's entitlements live is asked of xcodebuild (resolved settings), never guessed from
///   the pbxproj alone, so values inherited from `.xcconfig` files are respected and not overridden.
/// - Ambiguous situations (configurations disagreeing on whether there's an entitlements file,
///   generated projects) are refused with an explanation rather than guessed at.
/// - `apply` writes atomically, then re-checks with xcodebuild; any failure restores every file.
public enum ProjectEditor {
    struct ResolvedTarget {
        let file: PBXProjectFile
        let target: PBXProjectFile.Target
        /// Configuration name → resolved build settings.
        let settings: [String: [String: String]]
    }

    public static func planCapability(
        _ capability: Capability, values: [String], remove: Bool,
        path: String, target targetName: String?, force: Bool
    ) async throws -> EditPlan {
        let resolved = try await resolveTarget(path: path, name: targetName, force: force)
        let file = resolved.file
        let target = resolved.target
        var plan = EditPlan(target: target.name, projectURL: file.projectURL)

        let configs = target.configurations.map(\.name)
        let entitlementsByConfig = configs.reduce(into: [String: String]()) { result, name in
            if let value = resolved.settings[name]?["CODE_SIGN_ENTITLEMENTS"], !value.isEmpty { result[name] = value }
        }
        let bundleID = configs.lazy.compactMap { resolved.settings[$0]?["PRODUCT_BUNDLE_IDENTIFIER"] }.first ?? target.name

        var files: [URL]
        if entitlementsByConfig.isEmpty {
            if remove {
                plan.notes.append("\(target.name) has no entitlements file, so \(capability.title) isn't enabled")
                return plan
            }
            // Create one next to the target's sources and point every configuration at it.
            let folder = file.sourceFolder(of: target)
            let relative = [folder, "\(target.name).entitlements"].compactMap { $0 }.joined(separator: "/")
            let text = try PBXEditor.setBuildSetting(
                "CODE_SIGN_ENTITLEMENTS", to: relative,
                configurations: target.configurations.map(\.id), in: file.text)
            plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(text.utf8)))
            plan.notes.append("creating \(relative) and setting CODE_SIGN_ENTITLEMENTS for \(configs.joined(separator: ", "))")
            configs.forEach { plan.expectedEntitlements[$0] = relative }
            files = [file.projectDirectory.appendingPathComponent(relative)]
        } else if entitlementsByConfig.count < configs.count {
            let missing = configs.filter { entitlementsByConfig[$0] == nil }
            throw SochiError.mixedEntitlements(target: target.name, missing: missing)
        } else {
            files = Set(entitlementsByConfig.values).sorted().map { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path) : file.projectDirectory.appendingPathComponent(path)
            }
        }

        let entries = remove ? [:] : try capability.entries(values: values, bundleID: bundleID)
        for url in files {
            let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let current = try original.map { try Entitlements.parse($0, path: url.path) } ?? [:]
            let updated = remove
                ? try Capabilities.removing(capability, values: values, from: current)
                : Capabilities.adding(entries, to: current)
            if original != nil, NSDictionary(dictionary: updated).isEqual(to: current) {
                plan.notes.append("\(url.lastPathComponent): \(capability.title) already \(remove ? "absent" : "up to date")")
                continue
            }
            plan.edits.append(.init(url: url, original: original, updated: try Entitlements.serialize(updated)))
        }
        return plan
    }

    /// Writes every edit atomically, then verifies with xcodebuild. On any failure, restores all files.
    public static func apply(_ plan: EditPlan) async throws {
        var written: [EditPlan.FileEdit] = []
        do {
            for edit in plan.edits {
                try FileManager.default.createDirectory(at: edit.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try edit.updated.write(to: edit.url, options: .atomic)
                written.append(edit)
            }
            try await verify(plan)
        } catch {
            for edit in written.reversed() {
                if let original = edit.original {
                    try? original.write(to: edit.url, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: edit.url)
                }
            }
            throw error
        }
    }

    private static func verify(_ plan: EditPlan) async throws {
        for edit in plan.edits where edit.url.pathExtension == "entitlements" {
            _ = try Entitlements.parse(try Data(contentsOf: edit.url), path: edit.url.path)
        }
        // Re-parse the project ourselves, then confirm xcodebuild resolves the entitlements we intended.
        _ = try PBXProjectFile(projectURL: plan.projectURL)
        for (config, expected) in plan.expectedEntitlements {
            let settings = try await Xcodebuild.targetSettings(project: plan.projectURL, target: plan.target, configuration: config)
            guard settings["CODE_SIGN_ENTITLEMENTS"] == expected else {
                throw SochiError.editVerificationFailed(
                    "\(config) resolves CODE_SIGN_ENTITLEMENTS to '\(settings["CODE_SIGN_ENTITLEMENTS"] ?? "")', expected '\(expected)'")
            }
        }
    }

    /// The target's entitlements files and their contents, for display.
    public static func entitlements(path: String, target name: String?) async throws -> (target: String, files: [(URL, [String: Any])]) {
        let resolved = try await resolveTarget(path: path, name: name, force: true)
        let paths = Set(resolved.target.configurations.compactMap { resolved.settings[$0.name]?["CODE_SIGN_ENTITLEMENTS"] }
            .filter { !$0.isEmpty })
        let files = try paths.sorted().map { path -> (URL, [String: Any]) in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : resolved.file.projectDirectory.appendingPathComponent(path)
            return (url, try Entitlements.parse(try Data(contentsOf: url), path: url.path))
        }
        return (resolved.target.name, files)
    }

    // MARK: - Target resolution

    static func resolveTarget(path: String, name: String?, force: Bool) async throws -> ResolvedTarget {
        let project = try XcodeProject.locate(path)
        if !force, let marker = generatorMarker(in: project.directory) {
            throw SochiError.generatedProject(marker)
        }
        let files = try projectFiles(for: project).map { try PBXProjectFile(projectURL: $0) }
        let (file, target) = try pickTarget(named: name, in: files, project: project)

        let projectURL = file.projectURL
        let targetName = target.name
        let settings = try await withThrowingTaskGroup(of: (String, [String: String]).self) { group in
            for config in target.configurations.map(\.name) {
                group.addTask {
                    (config, try await Xcodebuild.targetSettings(project: projectURL, target: targetName, configuration: config))
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        return ResolvedTarget(file: file, target: target, settings: settings)
    }

    static func pickTarget(
        named name: String?, in files: [PBXProjectFile], project: XcodeProject
    ) throws -> (PBXProjectFile, PBXProjectFile.Target) {
        let all = files.flatMap { file in file.targets.map { (file, $0) } }
        if let name {
            guard let match = all.first(where: { $0.1.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw SochiError.unknownTarget(name, available: all.map(\.1.name))
            }
            return match
        }
        let apps = all.filter { $0.1.isApplication }
        if apps.count == 1 { return apps[0] }
        let preferred = [ProjectState.load(from: Paths.projectState(for: project)).scheme, project.name].compactMap { $0 }
        for candidate in preferred {
            if let match = apps.first(where: { $0.1.name == candidate }) { return match }
        }
        throw SochiError.ambiguousTarget(apps.isEmpty ? all.map(\.1.name) : apps.map(\.1.name))
    }

    /// The `.xcodeproj` bundles to search: the project itself, or a workspace's member projects (minus Pods).
    static func projectFiles(for project: XcodeProject) throws -> [URL] {
        guard project.kind == .workspace else { return [project.url] }
        let contents = project.url.appendingPathComponent("contents.xcworkspacedata")
        guard let xml = try? String(contentsOf: contents, encoding: .utf8) else { throw SochiError.unreadableProject(contents.path) }
        return xml.matches(of: #/location\s*=\s*"(?:group|container|absolute):([^"]+)"/#).compactMap { match in
            let path = String(match.1)
            guard path.hasSuffix(".xcodeproj"), !path.hasSuffix("Pods.xcodeproj") else { return nil }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : project.directory.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
        }
    }

    /// Generated projects get overwritten on regeneration, so editing them directly would silently lose changes.
    static func generatorMarker(in directory: URL) -> String? {
        ["project.yml", "project.yaml", "Project.swift", "Tuist.swift", "Tuist", "Workspace.swift"].first {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

enum Entitlements {
    static func parse(_ data: Data, path: String) throws -> [String: Any] {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SochiError.unreadableProject(path)
        }
        return dict
    }

    /// XML with tabs and sorted keys: byte-for-byte what Xcode writes.
    static func serialize(_ entitlements: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    }
}
