import Foundation

/// `sochi new`: a new project from one of Xcode's own project templates (the iOS App template by default), laid out
/// the way Xcode creates it: the template's project settings at project level, its target through `TargetBuilder`.
public enum ProjectCreator {
    public struct Result: Sendable {
        public let project: URL
        public let targets: [String]
        public let bundleIdentifier: String?
    }

    public static func create(
        name: String, in parent: URL, template query: String, options: [String: String],
        organization: String?, team: String?
    ) async throws -> Result {
        guard name.wholeMatch(of: #/[A-Za-z][A-Za-z0-9]*/#) != nil else { throw SochiError.invalidTargetName(name) }
        let directory = parent.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: directory.path) { throw SochiError.pathExists(directory.path) }

        async let loadedIndex = TemplateIndex.load()
        async let loadedSpecs = XcodeSpecs.load()
        async let toolsVersion = Xcodebuild.version()
        async let fullName = Shell.run(["id", "-F"])
        let (index, specs) = (try await loadedIndex, try await loadedSpecs)
        let template = try index.find(query)
        let configurations = ["Debug", "Release"]

        var givenOptions = options
        if let organization { givenOptions["bundleIdentifierPrefix"] = organization }
        let context = TemplateContext(
            name: name, projectName: name, hostBundleIdentifier: nil, hostProductName: nil, hostProductType: nil,
            developmentTeam: team, options: givenOptions,
            fullUserName: (try? await fullName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? NSFullUserName())
        let engine = TemplateEngine(index: index, specs: specs)

        // First pass: the template's project-level settings; second pass: target settings without them.
        let first = try engine.instantiate(template, context: context, projectSettings: [:], configurations: configurations)
        var projectLevel = first[0].projectSettings
        for config in configurations {
            projectLevel[config] = try await resolveLatest(projectLevel[config] ?? [:])
        }
        let projectAsAny = projectLevel.mapValues { settings in
            settings.mapValues { setting -> Any in
                switch setting { case .string(let s): s; case .list(let l): l }
            }
        }
        let outputs = try engine.instantiate(template, context: context, projectSettings: projectAsAny, configurations: configurations)

        let projectURL = directory.appendingPathComponent("\(name).xcodeproj")
        let version = try await toolsVersion
        var file = try PBXProjectFile(projectURL: projectURL, text: skeleton(name: name, settings: projectLevel, toolsVersion: version))
        var created: [String: String] = [:]
        var files: [(URL, Data)] = []
        for var output in outputs {
            for config in configurations {
                var settings = try await resolveLatest(output.settings[config] ?? [:])
                if settings["CODE_SIGN_STYLE"] == nil { settings["CODE_SIGN_STYLE"] = .string("Automatic") }
                if let team { settings["DEVELOPMENT_TEAM"] = .string(team) }
                output.settings[config] = settings
            }
            var spec = TargetSpec(name: output.targetName, folder: output.productName, productType: output.productType)
            spec.files = output.files
            spec.infoPlist = output.infoPlist
            spec.configurationSettings = output.settings
            spec.frameworks = output.frameworks
            var host: PBXProjectFile.Target?
            if let injection = output.injectInto, let id = created[injection] { host = file.targets.first { $0.id == id } }
            spec.embed = host != nil
            if let tested = output.testedTargetIdentifier.flatMap({ created[$0] }).flatMap({ id in file.targets.first { $0.id == id } }) {
                spec.dependencies = [(tested.id, tested.name)]
                for config in configurations {
                    let source = tested.configurations.first { $0.name == config }?.buildSettings ?? [:]
                    let copied = output.settingsToCopyFromTested.reduce(into: [String: String]()) { $0[$1] = source[$1] as? String }
                    TestWiring.apply(to: &spec.configurationSettings[config, default: [:]], productType: output.productType,
                                     testedName: tested.name, copied: copied)
                }
            }
            let rendered = try TargetBuilder.render(spec, in: file, host: host, specs: specs, toolsVersion: version)
            file = try PBXProjectFile(projectURL: projectURL, text: rendered.text)
            if let identifier = output.targetIdentifier { created[identifier] = rendered.targetID }
            let folder = directory.appendingPathComponent(output.productName)
            files += spec.files.map { (folder.appendingPathComponent($0.key), $0.value) }
            if let info = spec.infoPlist { files.append((folder.appendingPathComponent("Info.plist"), info)) }
        }

        // Write everything; on any failure, remove the half-made project.
        do {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: projectURL.appendingPathComponent("project.pbxproj"))
            for (url, data) in files {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            let listed = try await Shell.run(["xcodebuild", "-list", "-json", "-project", projectURL.path])
            for output in outputs where !listed.contains("\"\(output.targetName)\"") {
                throw SochiError.editVerificationFailed("xcodebuild doesn't list target \(output.targetName)")
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var bundleID: String?
        if case .string(let id)? = outputs.first?.settings["Debug"]?["PRODUCT_BUNDLE_IDENTIFIER"] { bundleID = id }
        return Result(project: projectURL, targets: outputs.map(\.targetName), bundleIdentifier: bundleID)
    }

    /// The organization identifier used last time, so `sochi new` needs `--org` only once.
    public static var rememberedOrganization: String? {
        get {
            guard let data = try? Data(contentsOf: defaultsURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
            return dict["organization"]
        }
        set {
            try? FileManager.default.createDirectory(at: defaultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["organization": newValue ?? ""], options: [.prettyPrinted]) {
                try? data.write(to: defaultsURL, options: .atomic)
            }
        }
    }

    static var defaultsURL: URL { Paths.stateRoot.appendingPathComponent("defaults.json") }

    /// `latest_<sdk>` means the installed SDK's version.
    static func resolveLatest(_ settings: [String: TargetSpec.Setting]) async throws -> [String: TargetSpec.Setting] {
        var result = settings
        for (key, value) in settings {
            guard case .string(let raw) = value, raw.hasPrefix("latest_") else { continue }
            let version = try await Shell.run(["xcrun", "--sdk", String(raw.dropFirst("latest_".count)), "--show-sdk-version"])
            result[key] = .string(version.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// An empty project in Xcode 16's format: project object, main and Products groups, project configurations.
    static func skeleton(name: String, settings: [String: [String: TargetSpec.Setting]], toolsVersion: String) -> String {
        let q = PBXEditor.quote
        let ids = (0..<6).map { _ in String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)) }
        let (root, main, products, list, debug, release) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        // Xcode records its version as major × 100 + minor, e.g. 27.0 → 2700.
        let parts = toolsVersion.split(separator: ".").compactMap { Int($0) }
        let check = String((parts.first ?? 0) * 100 + (parts.dropFirst().first ?? 0))
        func configuration(_ id: String, _ configName: String) -> [String] {
            var lines = ["\t\t\(id) /* \(configName) */ = {", "\t\t\tisa = XCBuildConfiguration;", "\t\t\tbuildSettings = {"]
            for (key, value) in (settings[configName] ?? [:]).sorted(by: { $0.key < $1.key }) {
                switch value {
                case .string(let s): lines.append("\t\t\t\t\(key) = \(q(s));")
                case .list(let items):
                    lines.append("\t\t\t\t\(key) = (")
                    lines += items.map { "\t\t\t\t\t\(q($0))," }
                    lines.append("\t\t\t\t);")
                }
            }
            return lines + ["\t\t\t};", "\t\t\tname = \(configName);", "\t\t};"]
        }
        let lines: [String] = [
            "// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {", "",
            "/* Begin PBXGroup section */",
            "\t\t\(main) = {", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = (", "\t\t\t\t\(products) /* Products */,", "\t\t\t);",
            "\t\t\tsourceTree = \"<group>\";", "\t\t};",
            "\t\t\(products) /* Products */ = {", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = (", "\t\t\t);", "\t\t\tname = Products;",
            "\t\t\tsourceTree = \"<group>\";", "\t\t};",
            "/* End PBXGroup section */", "",
            "/* Begin PBXProject section */",
            "\t\t\(root) /* Project object */ = {", "\t\t\tisa = PBXProject;", "\t\t\tattributes = {",
            "\t\t\t\tBuildIndependentTargetsInParallel = 1;", "\t\t\t\tLastSwiftUpdateCheck = \(check);", "\t\t\t\tLastUpgradeCheck = \(check);",
            "\t\t\t};",
            "\t\t\tbuildConfigurationList = \(list) /* Build configuration list for PBXProject \"\(name)\" */;",
            "\t\t\tdevelopmentRegion = en;", "\t\t\thasScannedForEncodings = 0;", "\t\t\tknownRegions = (", "\t\t\t\ten,", "\t\t\t\tBase,", "\t\t\t);",
            "\t\t\tmainGroup = \(main);", "\t\t\tminimizedProjectReferenceProxies = 1;", "\t\t\tpreferredProjectObjectVersion = 77;",
            "\t\t\tproductRefGroup = \(products) /* Products */;", "\t\t\tprojectDirPath = \"\";", "\t\t\tprojectRoot = \"\";",
            "\t\t\ttargets = (", "\t\t\t);", "\t\t};",
            "/* End PBXProject section */", "",
            "/* Begin XCBuildConfiguration section */",
        ] + configuration(debug, "Debug") + configuration(release, "Release") + [
            "/* End XCBuildConfiguration section */", "",
            "/* Begin XCConfigurationList section */",
            "\t\t\(list) /* Build configuration list for PBXProject \"\(name)\" */ = {", "\t\t\tisa = XCConfigurationList;",
            "\t\t\tbuildConfigurations = (", "\t\t\t\t\(debug) /* Debug */,", "\t\t\t\t\(release) /* Release */,", "\t\t\t);",
            "\t\t\tdefaultConfigurationIsVisible = 0;", "\t\t\tdefaultConfigurationName = Release;", "\t\t};",
            "/* End XCConfigurationList section */",
            "\t};", "\trootObject = \(root) /* Project object */;", "}", "",
        ]
        return lines.joined(separator: "\n")
    }
}
