import Foundation

/// Everything needed to create a target. Knowledge-free: callers (the generic `add target` path, or an
/// Xcode template) decide the product type, files and settings; `TargetBuilder` only wires them in.
public struct TargetSpec: Sendable {
    public enum Setting: Sendable, Equatable {
        case string(String)
        case list([String])
    }

    public var name: String
    /// Synchronized folder for the target's files, relative to the project directory.
    public var folder: String
    /// Any product type the selected Xcode defines, e.g. `com.apple.product-type.app-extension`.
    public var productType: String
    /// Files to create, relative to `folder`.
    public var files: [String: Data] = [:]
    /// Info.plist contents, written to `<folder>/Info.plist` and excluded from the target's resources.
    public var infoPlist: Data?
    /// Entitlements, written to `<folder>/<name>.entitlements`.
    public var entitlements: Data?
    /// Settings for every configuration.
    public var settings: [String: Setting] = [:]
    /// Per-configuration settings (by configuration name), applied over `settings`.
    public var configurationSettings: [String: [String: Setting]] = [:]
    /// System frameworks to link explicitly, e.g. `WidgetKit`.
    public var frameworks: [String] = []
    /// Embed the product in the host app using Xcode's embed rule for its product type.
    public var embed = true
    /// The product's SDK (e.g. `watchos`), for platform-specific embed rules; nil means the host's platform.
    public var sdk: String?

    public init(name: String, folder: String, productType: String) {
        self.name = name
        self.folder = folder
        self.productType = productType
    }
}

/// Renders a `TargetSpec` into `project.pbxproj` text the way Xcode lays it out (verified against
/// targets Xcode itself created, see Fixtures/Golden). Pure: no I/O, so it's testable without xcodebuild.
enum TargetBuilder {
    struct Output {
        let text: String
        let targetID: String
        let productID: String
    }

    static func render(
        _ spec: TargetSpec, in file: PBXProjectFile, host: PBXProjectFile.Target?, specs: XcodeSpecs, toolsVersion: String
    ) throws -> Output {
        guard specs.isKnown(spec.productType) else {
            throw SochiError.unknownProductType(spec.productType, suggestions: [])
        }
        guard let fileType = specs.productFileType(spec.productType) else {
            throw SochiError.xcodeDataUnavailable("the product file type for \(spec.productType)")
        }
        let rule = spec.embed && host != nil ? specs.embedRule(spec.productType, platform: spec.sdk) : nil
        if spec.embed, host != nil, rule == nil { throw SochiError.noEmbedRule(spec.productType) }

        var used = Set<String>()
        func id() -> String {
            while true {
                let candidate = PBXTextWriter.makeID(avoiding: file.text)
                if used.insert(candidate).inserted { return candidate }
            }
        }
        let q = PBXEditor.quote
        let target = id(), product = id(), group = id(), sources = id(), frameworksPhase = id(), resources = id(), list = id()
        let productName = spec.name + (specs.wrapperSuffix(spec.productType) ?? "")
        var writer = PBXTextWriter(file.text)

        writer.insert(object: [
            "\t\t\(product) /* \(productName) */ = {isa = PBXFileReference; explicitFileType = \(q(fileType)); includeInIndex = 0; path = \(q(productName)); sourceTree = BUILT_PRODUCTS_DIR; };",
        ], id: product, isa: "PBXFileReference")

        // Synchronized folder; Info.plist is processed by the build, so it's excluded from resources.
        var groupLines = ["\t\t\(group) /* \(spec.folder) */ = {", "\t\t\tisa = PBXFileSystemSynchronizedRootGroup;"]
        if spec.infoPlist != nil {
            let exceptions = id()
            let comment = "Exceptions for \"\(spec.folder)\" folder in \"\(spec.name)\" target"
            writer.insert(object: [
                "\t\t\(exceptions) /* \(comment) */ = {",
                "\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;",
                "\t\t\tmembershipExceptions = (",
                "\t\t\t\tInfo.plist,",
                "\t\t\t);",
                "\t\t\ttarget = \(target) /* \(spec.name) */;",
                "\t\t};",
            ], id: exceptions, isa: "PBXFileSystemSynchronizedBuildFileExceptionSet")
            groupLines += ["\t\t\texceptions = (", "\t\t\t\t\(exceptions) /* \(comment) */,", "\t\t\t);"]
        }
        groupLines += ["\t\t\tpath = \(q(spec.folder));", "\t\t\tsourceTree = \"<group>\";", "\t\t};"]
        writer.insert(object: groupLines, id: group, isa: "PBXFileSystemSynchronizedRootGroup")

        // Explicitly linked system frameworks, grouped under "Frameworks" like Xcode does.
        var frameworkFiles: [String] = []
        var frameworkRefs: [(String, String)] = []
        for framework in spec.frameworks {
            let ref = id(), buildFile = id()
            let name = "\(framework).framework"
            writer.insert(object: [
                "\t\t\(ref) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = \(q(name)); path = \(q("System/Library/Frameworks/\(name)")); sourceTree = SDKROOT; };",
            ], id: ref, isa: "PBXFileReference")
            writer.insert(object: [
                "\t\t\(buildFile) /* \(name) in Frameworks */ = {isa = PBXBuildFile; fileRef = \(ref) /* \(name) */; };",
            ], id: buildFile, isa: "PBXBuildFile")
            frameworkFiles.append("\(buildFile) /* \(name) in Frameworks */")
            frameworkRefs.append((ref, name))
        }

        for (phase, isa, label, files) in [(sources, "PBXSourcesBuildPhase", "Sources", [String]()),
                                           (frameworksPhase, "PBXFrameworksBuildPhase", "Frameworks", frameworkFiles),
                                           (resources, "PBXResourcesBuildPhase", "Resources", [String]())] {
            writer.insert(object: [
                "\t\t\(phase) /* \(label) */ = {",
                "\t\t\tisa = \(isa);",
                "\t\t\tbuildActionMask = 2147483647;",
                "\t\t\tfiles = (",
            ] + files.map { "\t\t\t\t\($0)," } + [
                "\t\t\t);",
                "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
                "\t\t};",
            ], id: phase, isa: isa)
        }

        writer.insert(object: [
            "\t\t\(target) /* \(spec.name) */ = {",
            "\t\t\tisa = PBXNativeTarget;",
            "\t\t\tbuildConfigurationList = \(list) /* Build configuration list for PBXNativeTarget \"\(spec.name)\" */;",
            "\t\t\tbuildPhases = (",
            "\t\t\t\t\(sources) /* Sources */,",
            "\t\t\t\t\(frameworksPhase) /* Frameworks */,",
            "\t\t\t\t\(resources) /* Resources */,",
            "\t\t\t);",
            "\t\t\tbuildRules = (",
            "\t\t\t);",
            "\t\t\tdependencies = (",
            "\t\t\t);",
            "\t\t\tfileSystemSynchronizedGroups = (",
            "\t\t\t\t\(group) /* \(spec.folder) */,",
            "\t\t\t);",
            "\t\t\tname = \(q(spec.name));",
            "\t\t\tpackageProductDependencies = (",
            "\t\t\t);",
            "\t\t\tproductName = \(q(spec.name));",
            "\t\t\tproductReference = \(product) /* \(productName) */;",
            "\t\t\tproductType = \(q(spec.productType));",
            "\t\t};",
        ], id: target, isa: "PBXNativeTarget")

        // One configuration per existing configuration name (the host's, else the project's).
        let configNames = host?.configurations.map(\.name) ?? file.projectConfigurationNames
        var configIDs: [(String, String)] = []
        for name in configNames {
            let configID = id()
            configIDs.append((configID, name))
            var settings = spec.settings
            if spec.infoPlist != nil { settings["INFOPLIST_FILE"] = .string("\(spec.folder)/Info.plist") }
            if spec.entitlements != nil { settings["CODE_SIGN_ENTITLEMENTS"] = .string("\(spec.folder)/\(spec.name).entitlements") }
            settings.merge(spec.configurationSettings[name] ?? [:]) { $1 }
            var lines = ["\t\t\(configID) /* \(name) */ = {", "\t\t\tisa = XCBuildConfiguration;", "\t\t\tbuildSettings = {"]
            for key in settings.keys.sorted() {
                switch settings[key]! {
                case .string(let value):
                    lines.append("\t\t\t\t\(key) = \(q(value));")
                case .list(let values):
                    lines.append("\t\t\t\t\(key) = (")
                    lines += values.map { "\t\t\t\t\t\(q($0))," }
                    lines.append("\t\t\t\t);")
                }
            }
            lines += ["\t\t\t};", "\t\t\tname = \(q(name));", "\t\t};"]
            writer.insert(object: lines, id: configID, isa: "XCBuildConfiguration")
        }
        let hostList = host.flatMap { file.objects[$0.id]?["buildConfigurationList"] as? String }
            ?? file.objects[file.rootID]?["buildConfigurationList"] as? String ?? ""
        let defaultConfig = file.objects[hostList]?["defaultConfigurationName"] as? String ?? "Release"
        writer.insert(object: [
            "\t\t\(list) /* Build configuration list for PBXNativeTarget \"\(spec.name)\" */ = {",
            "\t\t\tisa = XCConfigurationList;",
            "\t\t\tbuildConfigurations = (",
        ] + configIDs.map { "\t\t\t\t\($0.0) /* \($0.1) */," } + [
            "\t\t\t);",
            "\t\t\tdefaultConfigurationIsVisible = 0;",
            "\t\t\tdefaultConfigurationName = \(q(defaultConfig));",
            "\t\t};",
        ], id: list, isa: "XCConfigurationList")

        // Embed in the host (reusing a matching copy phase) and make the host depend on the new target.
        if let host, let rule {
            let buildFile = id()
            writer.insert(object: [
                "\t\t\(buildFile) /* \(productName) in \(rule.phaseName) */ = {isa = PBXBuildFile; fileRef = \(product) /* \(productName) */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };",
            ], id: buildFile, isa: "PBXBuildFile")
            let existing = (file.objects[host.id]?["buildPhases"] as? [String] ?? []).first { phase in
                let object = file.objects[phase]
                return object?["isa"] as? String == "PBXCopyFilesBuildPhase"
                    && object?["dstSubfolderSpec"] as? String == rule.dstSubfolderSpec
                    && (object?["dstPath"] as? String ?? "") == rule.dstPath
            }
            if let existing {
                try writer.append("\(buildFile) /* \(productName) in \(rule.phaseName) */", to: "files", ofObject: existing)
            } else {
                let phase = id()
                writer.insert(object: [
                    "\t\t\(phase) /* \(rule.phaseName) */ = {",
                    "\t\t\tisa = PBXCopyFilesBuildPhase;",
                    "\t\t\tbuildActionMask = 2147483647;",
                    "\t\t\tdstPath = \(q(rule.dstPath));",
                    "\t\t\tdstSubfolderSpec = \(rule.dstSubfolderSpec);",
                    "\t\t\tfiles = (",
                    "\t\t\t\t\(buildFile) /* \(productName) in \(rule.phaseName) */,",
                    "\t\t\t);",
                    "\t\t\tname = \(q(rule.phaseName));",
                    "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
                    "\t\t};",
                ], id: phase, isa: "PBXCopyFilesBuildPhase")
                try writer.append("\(phase) /* \(rule.phaseName) */", to: "buildPhases", ofObject: host.id)
            }
            let proxy = id(), dependency = id()
            writer.insert(object: [
                "\t\t\(proxy) /* PBXContainerItemProxy */ = {",
                "\t\t\tisa = PBXContainerItemProxy;",
                "\t\t\tcontainerPortal = \(file.rootID) /* Project object */;",
                "\t\t\tproxyType = 1;",
                "\t\t\tremoteGlobalIDString = \(target);",
                "\t\t\tremoteInfo = \(q(spec.name));",
                "\t\t};",
            ], id: proxy, isa: "PBXContainerItemProxy")
            writer.insert(object: [
                "\t\t\(dependency) /* PBXTargetDependency */ = {",
                "\t\t\tisa = PBXTargetDependency;",
                "\t\t\ttarget = \(target) /* \(spec.name) */;",
                "\t\t\ttargetProxy = \(proxy) /* PBXContainerItemProxy */;",
                "\t\t};",
            ], id: dependency, isa: "PBXTargetDependency")
            try writer.append("\(dependency) /* PBXTargetDependency */", to: "dependencies", ofObject: host.id)
        }

        // Project lists: targets, attributes, Products, and the main group (folders before Frameworks and Products).
        let root = file.objects[file.rootID] ?? [:]
        try writer.append("\(target) /* \(spec.name) */", to: "targets", ofObject: file.rootID)
        writer.addTargetAttributes(projectID: file.rootID, targetID: target, toolsVersion: toolsVersion)
        let products = root["productRefGroup"] as? String
        if let products {
            try writer.append("\(product) /* \(productName) */", to: "children", ofObject: products)
        }
        if let main = root["mainGroup"] as? String {
            let children = file.objects[main]?["children"] as? [String] ?? []
            var frameworksGroup = children.first { file.objects[$0]?["isa"] as? String == "PBXGroup" && file.objects[$0]?["name"] as? String == "Frameworks" }
            if frameworksGroup == nil, !frameworkRefs.isEmpty {
                let groupID = id()
                writer.insert(object: [
                    "\t\t\(groupID) /* Frameworks */ = {",
                    "\t\t\tisa = PBXGroup;",
                    "\t\t\tchildren = (",
                    "\t\t\t);",
                    "\t\t\tname = Frameworks;",
                    "\t\t\tsourceTree = \"<group>\";",
                    "\t\t};",
                ], id: groupID, isa: "PBXGroup")
                try writer.append("\(groupID) /* Frameworks */", to: "children", ofObject: main, before: products)
                frameworksGroup = groupID
            }
            for (ref, name) in frameworkRefs {
                try writer.append("\(ref) /* \(name) */", to: "children", ofObject: frameworksGroup!)
            }
            try writer.append("\(group) /* \(spec.folder) */", to: "children", ofObject: main, before: frameworksGroup ?? products)
        }

        let text = writer.text
        try verify(text: text, path: file.pbxprojURL.path, rootID: file.rootID, host: rule == nil ? nil : host?.id,
                   target: target, product: product, configurations: configNames.count)
        return Output(text: text, targetID: target, productID: product)
    }

    /// Re-parses the edited project and checks every link a broken edit could miss.
    static func verify(text: String, path: String, rootID: String, host: String?, target: String, product: String, configurations: Int) throws {
        let objects = try PBXProjectFile.objects(in: text, path: path)
        func fail(_ what: String) -> SochiError { .editVerificationFailed(what) }
        guard objects[target]?["isa"] as? String == "PBXNativeTarget" else { throw fail("new target missing") }
        guard (objects[rootID]?["targets"] as? [String])?.contains(target) == true else { throw fail("target not in project") }
        let list = objects[target]?["buildConfigurationList"] as? String ?? ""
        guard (objects[list]?["buildConfigurations"] as? [String])?.count == configurations else {
            throw fail("configurations incomplete")
        }
        for group in objects[target]?["fileSystemSynchronizedGroups"] as? [String] ?? [] where objects[group] == nil {
            throw fail("folder reference dangling")
        }
        guard let host else { return }
        let dependencies = objects[host]?["dependencies"] as? [String] ?? []
        guard dependencies.contains(where: { objects[$0]?["target"] as? String == target }) else { throw fail("host dependency missing") }
        let embedded = (objects[host]?["buildPhases"] as? [String] ?? []).contains { phase in
            (objects[phase]?["files"] as? [String] ?? []).contains { objects[$0]?["fileRef"] as? String == product }
        }
        guard embedded else { throw fail("product not embedded in host") }
    }
}

extension PBXProjectFile {
    /// The project-level build settings of each configuration, by name.
    var projectBuildSettings: [String: [String: Any]] {
        let list = objects[rootID]?["buildConfigurationList"] as? String ?? ""
        return (objects[list]?["buildConfigurations"] as? [String] ?? []).reduce(into: [:]) { result, id in
            if let name = objects[id]?["name"] as? String { result[name] = objects[id]?["buildSettings"] as? [String: Any] ?? [:] }
        }
    }

    /// Configuration names of the project itself, for targets created without a host.
    var projectConfigurationNames: [String] {
        let list = objects[rootID]?["buildConfigurationList"] as? String ?? ""
        return (objects[list]?["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0]?["name"] as? String }
    }
}

extension PBXTextWriter {
    /// Records `CreatedOnToolsVersion` for a new target under the project's `TargetAttributes`, sorted by ID.
    mutating func addTargetAttributes(projectID: String, targetID: String, toolsVersion: String) {
        let entry = ["\t\t\t\t\t\(targetID) = {", "\t\t\t\t\t\tCreatedOnToolsVersion = \(PBXEditor.quote(toolsVersion));", "\t\t\t\t\t};"]
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\t\t\(projectID) ") && $0.hasSuffix("= {") }),
              let end = lines[start...].firstIndex(of: "\t\t};"),
              let attributes = lines[start..<end].firstIndex(of: "\t\t\tattributes = {"),
              let attributesEnd = lines[attributes..<end].firstIndex(of: "\t\t\t};")
        else { return }
        if let open = lines[attributes..<attributesEnd].firstIndex(of: "\t\t\t\tTargetAttributes = {"),
           let close = lines[open..<attributesEnd].firstIndex(of: "\t\t\t\t};") {
            let position = lines[(open + 1)..<close].firstIndex { line in
                line.hasPrefix("\t\t\t\t\t") && !line.hasPrefix("\t\t\t\t\t\t") && line.hasSuffix(" = {")
                    && line.trimmingCharacters(in: .whitespaces) > "\(targetID) = {"
            } ?? close
            lines.insert(contentsOf: entry, at: position)
        } else {
            lines.insert(contentsOf: ["\t\t\t\tTargetAttributes = {"] + entry + ["\t\t\t\t};"], at: attributesEnd)
        }
    }
}
