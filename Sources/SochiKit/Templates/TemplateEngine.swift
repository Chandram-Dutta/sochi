import Foundation

/// Everything a template needs to know about where it's being instantiated.
struct TemplateContext {
    /// The product name the user chose (`___PACKAGENAME___`).
    var name: String
    var projectName: String
    /// The host app, for templates that embed in one.
    var hostBundleIdentifier: String?
    var hostProductName: String?
    var hostProductType: String?
    var developmentTeam: String?
    /// Option values given on the command line, by option identifier.
    var options: [String: String] = [:]
    var fullUserName: String
    var date: Date = Date()
    /// `IDETemplateMacros.plist` overrides (e.g. a custom FILEHEADER), if the project or user defines them.
    var macroOverrides: [String: String] = [:]
    /// The outer template's product name, for components (`___VARIABLE_productName___` stays the user's name).
    var outerProductName: String?
    /// Whether the outermost template embeds into the existing host app (vs. creating a new app beside it).
    var hosted = false
    /// "Requirement if associated target" constraints apply only when adding to an existing target, not to a
    /// component created alongside its parent (as when Xcode creates both in one go).
    var appliesAssociationConstraints = true
}

/// The output of instantiating a template: files for the target's folder, and the target to create.
struct TemplateOutput {
    var targetName: String
    var productType: String
    /// File path (relative to the target folder) → contents.
    var files: [String: Data] = [:]
    var infoPlist: Data?
    /// Configuration name → settings, before host alignment.
    var settings: [String: [String: TargetSpec.Setting]] = [:]
    var frameworks: [String] = []
    var embed: Bool
    var resolvedOptions: [String: String] = [:]
    /// The template's own identifier for this target (siblings refer to it to be embedded in it).
    var targetIdentifier: String?
    /// For a component: embed into the sibling target with this identifier (`ProductBuildPhaseInjections`).
    var injectInto: String?
    /// The product name used for this target's folder and macros (a component's own `Name`).
    var productName: String = ""
    var isComponent = false
    /// The template's project-level settings by configuration (what a new project gets at project level).
    var projectSettings: [String: [String: TargetSpec.Setting]] = [:]
    /// For test bundles: the template target identifier of the target under test, and settings to copy from it.
    var testedTargetIdentifier: String?
    var settingsToCopyFromTested: [String] = []
}

/// Interprets Xcode's TemplateInfo.plist format: options and the units they select, `___MACRO___` expansion,
/// file nodes, Info.plist fragments and asset generation. What the format can't express (how a target is wired
/// into the project) is `TargetBuilder`'s job.
struct TemplateEngine {
    let index: TemplateIndex
    let specs: XcodeSpecs

    /// Instantiates a template and its components; outputs are in creation order (a target before components that
    /// embed into it).
    func instantiate(_ template: XcodeTemplate, context: TemplateContext, projectSettings: [String: [String: Any]],
                     configurations: [String], isComponent: Bool = false) throws -> [TemplateOutput] {
        var resolved = index.resolve(template)
        guard resolved.targets.count <= 1 else { throw SochiError.unsupportedTemplate(template.name, "it defines several targets itself") }
        if let association = resolved.association, !isComponent {
            guard let hostType = context.hostProductType else { throw SochiError.templateNeedsHost(template.name) }
            let allowed = association["AllowableProductTypes"] as? [String] ?? []
            if !allowed.isEmpty, !allowed.contains(hostType) {
                throw SochiError.unsupportedTemplate(template.name, "it can't be hosted by a \(hostType) target")
            }
        }

        // Options: forced values, then the user's, then defaults; host constraints win when there is a host.
        var values: [String: String] = ["productName": context.outerProductName ?? context.name]
        var variables: [String: String] = [:]
        for option in resolved.options {
            guard let id = option["Identifier"] as? String, id != "productName" else { continue }
            if let forced = option["Override"] { values[id] = "\(forced)" }
            else if let given = context.options[id] { values[id] = given }
            else if let fallback = option["Default"] { values[id] = "\(fallback)" }
        }
        let known = Set(resolved.options.compactMap { $0["Identifier"] as? String })
        if !isComponent, let unknown = context.options.keys.first(where: { !known.contains($0) }) {
            throw SochiError.unknownTemplateOption(unknown, available: optionSummaries(resolved.options))
        }
        // A companion chooser with an existing host: the choice whose components embed into it rather than into
        // targets the template creates (i.e. none of its components declares ProductBuildPhaseInjections).
        if context.hostBundleIdentifier != nil {
            for option in resolved.options where option["Type"] as? String == "companionAppTargetChooser" {
                guard let id = option["Identifier"] as? String, context.options[id] == nil else { continue }
                let existing = (option["Values"] as? [String] ?? []).first { value in
                    let units = resolved.units[id]?[value] ?? []
                    let components = units.flatMap { $0.unit["Components"] as? [[String: Any]] ?? [] }
                    return !components.isEmpty && components.allSatisfy { $0["ProductBuildPhaseInjections"] == nil }
                }
                if let existing { values[id] = existing }
            }
        }
        if context.hostBundleIdentifier != nil, context.appliesAssociationConstraints {
            for constraint in resolved.constraints where constraint["ConstraintType"] as? String == "RequirementIfAssociatedTarget" {
                if let id = constraint["Identifier"] as? String, let value = constraint["Value"] { values[id] = "\(value)" }
            }
        }
        // The organization identifier, when nothing set it: the host's bundle ID for targets that live inside the host
        // (Apple requires e.g. a companion watch app's ID to start with its iOS app's), otherwise the host's prefix.
        let hosted = context.hosted || (!isComponent && resolved.association != nil)
        if values["bundleIdentifierPrefix"] == nil, let host = context.hostBundleIdentifier {
            values["bundleIdentifierPrefix"] = hosted ? host : host.split(separator: ".").dropLast().joined(separator: ".")
        }
        for option in resolved.options {
            if let id = option["Identifier"] as? String, values[id]?.isEmpty ?? true, let replacement = option["EmptyReplacement"] {
                values[id] = "\(replacement)"
            }
        }
        for option in resolved.options {
            guard let id = option["Identifier"] as? String, let value = values[id] else { continue }
            if let vars = (option["Variables"] as? [String: Any])?[value] as? [String: String] { variables.merge(vars) { $1 } }
            for (candidate, directory) in resolved.units[id]?[value] ?? [] {
                let required = candidate["RequiredOptions"] as? [String: Any] ?? [:]
                if required.allSatisfy({ values[$0.key] == "\($0.value)" }) {
                    resolved.merge(candidate, from: directory)
                }
            }
        }

        var macros = MacroExpander(context: context, options: values, variables: variables)
        var outputs: [TemplateOutput] = []
        if let target = resolved.targets.first, target["ProductType"] is String {
            outputs.append(try instantiateTarget(
                template, resolved: resolved, target: target, values: values, macros: &macros, isComponent: isComponent,
                projectSettings: projectSettings, configurations: configurations))
        }
        // Components: other templates instantiated alongside, each under its own (macro-expanded) name.
        for case let component as [String: Any] in resolved.components {
            guard let id = component["Identifier"] as? String, let componentTemplate = index.templates[id] else {
                throw SochiError.unsupportedTemplate(template.name, "a component template is missing")
            }
            var componentContext = context
            componentContext.name = try macros.expand(component["Name"] as? String ?? "___PACKAGENAME___", file: nil)
            componentContext.outerProductName = context.outerProductName ?? context.name
            componentContext.hosted = hosted
            // Components see the outer template's choices (organization identifier, language, …).
            for (key, value) in values where componentContext.options[key] == nil && key != "productName" {
                componentContext.options[key] = value
            }
            // A component embedded into a sibling this template creates is associated with that sibling, not the host.
            let injection = (component["ProductBuildPhaseInjections"] as? [[String: Any]])?.first?["TargetIdentifier"] as? String
            if let injection, let sibling = outputs.first(where: { $0.targetIdentifier == injection }) {
                if case .string(let bundleID)? = sibling.settings[configurations.first ?? ""]?["PRODUCT_BUNDLE_IDENTIFIER"] {
                    componentContext.hostBundleIdentifier = bundleID
                }
                componentContext.hostProductName = sibling.productName
                componentContext.hostProductType = sibling.productType
                componentContext.appliesAssociationConstraints = false
            }
            var produced = try instantiate(componentTemplate, context: componentContext, projectSettings: projectSettings,
                                           configurations: configurations, isComponent: true)
            if !produced.isEmpty { produced[0].injectInto = injection }
            outputs += produced
        }
        guard !outputs.isEmpty else { throw SochiError.unsupportedTemplate(template.name, "it doesn't define a product type") }
        return outputs
    }

    private func instantiateTarget(
        _ template: XcodeTemplate, resolved: ResolvedTemplate, target: [String: Any], values: [String: String],
        macros: inout MacroExpander, isComponent: Bool, projectSettings: [String: [String: Any]], configurations: [String]
    ) throws -> TemplateOutput {
        let productType = target["ProductType"] as! String
        let context = macros.context
        let targetName = try macros.expand(target["Name"] as? String ?? "___PACKAGENAME___", file: nil)
        macros.targetName = targetName
        var output = TemplateOutput(
            targetName: targetName, productType: productType,
            frameworks: target["Frameworks"] as? [String] ?? [],
            embed: resolved.association.map { $0["AssociatedTargetNeedsProductBuildPhaseInjection"] as? Bool ?? true } ?? false,
            resolvedOptions: values, targetIdentifier: target["TargetIdentifier"] as? String,
            productName: context.name, isComponent: isComponent,
            testedTargetIdentifier: target["TargetIdentifierToBeTested"] as? String,
            settingsToCopyFromTested: target["SettingsToCopyFromTargetBeingTested"] as? [String] ?? [])

        // Files and Info.plist fragments.
        var infoPlist: [String: Any] = [:]
        for node in resolved.nodes {
            let definition = resolved.definitions[node]
            if node.hasPrefix("Info.plist:") {
                guard let fragment = definition?.value as? String, !fragment.isEmpty else { continue }
                let parents = node.split(separator: ":").dropFirst().dropLast().map(String.init)
                let parsed = try parsePlistFragment(try macros.expand(fragment, file: "Info.plist"), template: template.name)
                infoPlist = Self.merge(parsed, into: infoPlist, at: parents)
                continue
            }
            if node == "Info.plist" { continue }
            let destination = try macros.expand(node, file: nil)
            if let spec = definition?.value as? [String: Any] {
                guard let path = spec["Path"] as? String else {
                    throw SochiError.unsupportedTemplate(template.name, "file \(node) is assembled from code fragments (Objective-C or storyboard variants)")
                }
                // Source names are literal (some contain macros, e.g. `___PACKAGENAMEASIDENTIFIER___.entitlements`).
                var source = definition!.directory.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: source.path) {
                    source = definition!.directory.appendingPathComponent(try macros.expand(path, file: nil))
                }
                try copy(source, to: destination, into: &output.files, macros: &macros, template: template.name)
                for generation in spec["AssetGeneration"] as? [[String: Any]] ?? [] {
                    try generateAsset(generation, catalog: destination, into: &output.files, macros: macros, template: template.name)
                }
            } else if definition == nil, FileManager.default.fileExists(atPath: template.directory.appendingPathComponent(node).path) {
                try copy(template.directory.appendingPathComponent(node), to: destination, into: &output.files, macros: &macros, template: template.name)
            } else if node.contains(":") {
                throw SochiError.unsupportedTemplate(template.name, "it assembles \(node) from code fragments")
            }
        }
        if !infoPlist.isEmpty {
            output.infoPlist = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        }

        // Settings: the template's project settings the project doesn't define, then the target's own.
        let projectShared = resolved.project["SharedSettings"] as? [String: Any] ?? [:]
        let projectConfigs = resolved.project["Configurations"] as? [String: [String: Any]] ?? [:]
        let targetShared = target["SharedSettings"] as? [String: Any] ?? [:]
        let targetConfigs = target["Configurations"] as? [String: [String: Any]] ?? [:]
        func setting(_ key: String, _ raw: Any) throws -> TargetSpec.Setting {
            let value = try macros.expand("\(raw)", file: nil)
            // Observed in Xcode's output (Fixtures/Golden): list-typed settings are written as arrays when they
            // extend an inherited value, and kept as strings otherwise. Both forms build identically.
            let asList = specs.listSettings.contains(key) && value.contains("$(inherited)")
            return asList ? .list(Self.splitList(value)) : .string(value)
        }
        for config in configurations {
            var projectLevel = try projectShared.merging(projectConfigs[config] ?? [:]) { $1 }.mapValues { $0 }
                .reduce(into: [String: TargetSpec.Setting]()) { $0[$1.key] = try setting($1.key, $1.value) }
            if let sdk = resolved.project["SDK"] as? String { projectLevel["SDKROOT"] = .string(sdk) }
            output.projectSettings[config] = projectLevel
        }
        for config in configurations {
            let existing = projectSettings[config] ?? [:]
            var merged = projectShared.merging(projectConfigs[config] ?? [:]) { $1 }.filter { existing[$0.key] == nil }
            merged.merge(targetShared) { $1 }
            merged.merge(targetConfigs[config] ?? [:]) { $1 }
            if output.infoPlist == nil { merged["INFOPLIST_FILE"] = nil }
            // A template for another platform (e.g. a watchOS app in an iOS project) sets its SDK on the target.
            if let sdk = resolved.project["SDK"] as? String, sdk != (existing["SDKROOT"] as? String ?? "iphoneos") {
                merged["SDKROOT"] = merged["SDKROOT"] ?? sdk
            }
            var settings: [String: TargetSpec.Setting] = [:]
            for (key, raw) in merged {
                let value = try macros.expand("\(raw)", file: nil)
                // Observed in Xcode's output (Fixtures/Golden): list-typed settings are written as arrays when they
                // extend an inherited value, and kept as strings otherwise. Both forms build identically.
                let asList = specs.listSettings.contains(key) && value.contains("$(inherited)")
                settings[key] = asList ? .list(Self.splitList(value)) : .string(value)
            }
            output.settings[config] = settings
        }
        return output
    }

    // MARK: Files

    private func copy(_ source: URL, to destination: String, into files: inout [String: Data],
                      macros: inout MacroExpander, template: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw SochiError.unsupportedTemplate(template, "its file \(source.lastPathComponent) is missing")
        }
        if isDirectory.boolValue {
            let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])
            while let url = walker?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
                let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
                files["\(destination)/\(relative)"] = try Data(contentsOf: url)
            }
            return
        }
        let data = try Data(contentsOf: source)
        // Text files get macro substitution, as in Xcode; binary files are copied as-is.
        if let text = String(data: data, encoding: .utf8) {
            files[destination] = Data(try macros.expand(text, file: (destination as NSString).lastPathComponent).utf8)
        } else {
            files[destination] = data
        }
    }

    /// Xcode generates some asset sets in code instead of shipping them in templates. sochi writes the same slot
    /// layouts (the iOS one is checked against Xcode's own output in Fixtures/Golden; actool validates the others at
    /// build time), and refuses generators it doesn't know rather than leaving an app icon set missing.
    private func generateAsset(_ generation: [String: Any], catalog: String, into files: inout [String: Data],
                               macros: MacroExpander, template: String) throws {
        guard let type = generation["Type"] as? String, let name = generation["Name"] as? String else { return }
        let platforms = try (generation["Platforms"] as? [String: Any] ?? ["iOS": "true"]).compactMap { platform, flag in
            try macros.expand("\(flag)", file: nil) == "true" ? platform : nil
        }
        func slot(_ fields: [(String, String)], appearance: String? = nil) -> [String: Any] {
            var image: [String: Any] = Dictionary(uniqueKeysWithValues: fields)
            if let appearance { image["appearances"] = [["appearance": "luminosity", "value": appearance]] }
            return image
        }
        var images: [[String: Any]] = []
        let folder: String
        switch type {
        case "appicon":
            folder = "\(name).appiconset"
            if platforms.contains("iOS") {
                let ios = [("idiom", "universal"), ("platform", "ios"), ("size", "1024x1024")]
                images += [slot(ios), slot(ios, appearance: "dark"), slot(ios, appearance: "tinted")]
            }
            if platforms.contains("watchOS") {
                images.append(slot([("idiom", "universal"), ("platform", "watchos"), ("size", "1024x1024")]))
            }
            if platforms.contains("macOS") {
                for size in ["16x16", "32x32", "128x128", "256x256", "512x512"] {
                    for scale in ["1x", "2x"] { images.append(slot([("idiom", "mac"), ("scale", scale), ("size", size)])) }
                }
            }
        case "stickersicon":
            folder = "\(name).stickersiconset"
            let slots: [(String, String, String, String?)] = [
                ("iphone", "2x", "29x29", nil), ("iphone", "3x", "29x29", nil), ("iphone", "2x", "60x45", nil),
                ("iphone", "3x", "60x45", nil), ("ipad", "2x", "29x29", nil), ("ipad", "2x", "67x50", nil),
                ("ipad", "2x", "74x55", nil), ("ios-marketing", "1x", "1024x1024", nil),
                ("universal", "2x", "27x20", "ios"), ("universal", "3x", "27x20", "ios"),
                ("universal", "2x", "32x24", "ios"), ("universal", "3x", "32x24", "ios"),
                ("ios-marketing", "1x", "1024x768", "ios"),
            ]
            images = slots.map { idiom, scale, size, platform in
                slot([("idiom", idiom), ("scale", scale), ("size", size)] + (platform.map { [("platform", $0)] } ?? []))
            }
        default:
            throw SochiError.unsupportedTemplate(template, "it needs Xcode to generate a \(type) asset")
        }
        guard !images.isEmpty else { return }
        let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        // Match Xcode's asset JSON style: `"key" : value` and a trailing newline.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\": ", with: "\" : ") + "\n"
        data = Data(text.utf8)
        files["\(catalog)/\(folder)/Contents.json"] = data
    }

    // MARK: Helpers

    private func parsePlistFragment(_ fragment: String, template: String) throws -> [String: Any] {
        let wrapped = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>\(fragment)</dict></plist>"
        guard let dict = try? PropertyListSerialization.propertyList(from: Data(wrapped.utf8), format: nil) as? [String: Any] else {
            throw SochiError.unsupportedTemplate(template, "an Info.plist fragment didn't parse")
        }
        return dict
    }

    static func merge(_ fragment: [String: Any], into plist: [String: Any], at path: [String]) -> [String: Any] {
        guard let first = path.first else { return plist.merging(fragment) { $1 } }
        var result = plist
        result[first] = merge(fragment, into: plist[first] as? [String: Any] ?? [:], at: Array(path.dropFirst()))
        return result
    }

    /// Splits a list-typed setting the way Xcode does: on whitespace, keeping quoted parts together.
    static func splitList(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if let q = quote {
                if character == q { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { items.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { items.append(current) }
        return items
    }

    private func optionSummaries(_ options: [[String: Any]]) -> [String] {
        options.compactMap { option in
            guard let id = option["Identifier"] as? String, option["Override"] == nil,
                  !["productName", "bundleIdentifierPrefix", "bundleIdentifier", "languageChoice"].contains(id),
                  let type = option["Type"] as? String, type != "static" else { return nil }
            let values = (option["Values"] as? [String]) ?? (type == "checkbox" ? ["true", "false"] : [])
            return values.isEmpty ? id : "\(id)=\(values.joined(separator: "|"))"
        }
    }

    /// The user-settable options of a template, for help output.
    func options(of template: XcodeTemplate) -> [String] {
        optionSummaries(index.resolve(template).options)
    }
}

/// Expands Xcode's `___NAME___` / `___NAME:modifier___` template macros.
struct MacroExpander {
    let context: TemplateContext
    let options: [String: String]
    let variables: [String: String]
    var targetName: String?

    init(context: TemplateContext, options: [String: String], variables: [String: String]) {
        self.context = context
        self.options = options
        self.variables = variables
    }

    func expand(_ text: String, file: String?, depth: Int = 0) throws -> String {
        guard text.contains("___"), depth < 8 else { return text }
        var result = ""
        var rest = Substring(text)
        while let match = rest.firstMatch(of: #/___([A-Za-z][A-Za-z0-9_]*?)(?::([A-Za-z0-9]+))?___/#) {
            result += rest[..<match.range.lowerBound]
            let name = String(match.1)
            guard let raw = try value(of: name, file: file) else {
                throw SochiError.unsupportedTemplateMacro(name)
            }
            result += Self.apply(match.2.map(String.init), to: try expand(raw, file: file, depth: depth + 1))
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }

    private func value(of name: String, file: String?) throws -> String? {
        let base = file.map { ($0 as NSString).deletingPathExtension } ?? context.name
        switch name {
        case "PACKAGENAME", "PRODUCTNAME": return context.name
        case "PACKAGENAMEASIDENTIFIER": return Self.apply("identifier", to: context.name)
        case "PACKAGENAMEASRFC1034IDENTIFIER": return Self.apply("rfc1034identifier", to: context.name)
        case "PACKAGENAMEASXML": return Self.apply("xml", to: context.name)
        case "TARGETNAME": return targetName ?? context.name
        case "PROJECTNAME", "PARENTPACKAGENAME": return context.projectName
        case "FILENAME": return file ?? context.name
        case "FILEBASENAME": return base
        case "FILEBASENAMEASIDENTIFIER": return Self.apply("identifier", to: base)
        case "FILEHEADER":
            if let custom = context.macroOverrides["FILEHEADER"] { return custom }
            let date = DateFormatter.localizedString(from: context.date, dateStyle: .short, timeStyle: .none)
            return "\n//  \(file ?? context.name)\n//  \(context.name)\n//\n//  Created by \(context.fullUserName) on \(date).\n//"
        case "COPYRIGHT", "ORGANIZATIONNAME": return context.macroOverrides[name] ?? ""
        case "FULLUSERNAME": return context.fullUserName
        case "DATE": return DateFormatter.localizedString(from: context.date, dateStyle: .short, timeStyle: .none)
        case "YEAR": return String(Calendar.current.component(.year, from: context.date))
        case "DEVELOPMENTTEAMIDENTIFIER": return context.developmentTeam ?? ""
        case "ASSOCIATEDTARGET_bundleIdentifier": return context.hostBundleIdentifier ?? ""
        case "ASSOCIATEDTARGET_bundleName", "ASSOCIATEDTARGET_bundleDisplayName": return context.hostProductName ?? ""
        default:
            if name.hasPrefix("VARIABLE_") {
                let key = String(name.dropFirst("VARIABLE_".count))
                return options[key] ?? variables[key] ?? context.macroOverrides[key]
            }
            if name.hasPrefix("UUID") { return UUID().uuidString }
            return context.macroOverrides[name]
        }
    }

    static func apply(_ modifier: String?, to value: String) -> String {
        switch modifier?.lowercased() {
        case nil: return value
        case "identifier", "c99extidentifier":
            var result = String(value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            if result.first?.isNumber == true { result = "_" + result }
            return result
        case "rfc1034identifier":
            return String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "-" })
        case "bundleidentifier":
            return String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "-" })
        case "xml":
            return value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        default: return value
        }
    }
}
