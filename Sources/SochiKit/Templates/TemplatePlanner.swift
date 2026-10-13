import Foundation

extension ProjectEditor {
    /// Plans a target from one of Xcode's own templates, like File › New › Target. Template content (files,
    /// settings, Info.plist) comes from the selected Xcode; wiring is `TargetBuilder`'s. Versioning, Swift version
    /// and deployment target follow the host app (deviations from the template are reported in the notes).
    public static func planTemplateTarget(
        template query: String, name: String, options: [String: String], path: String, host hostName: String?, force: Bool
    ) async throws -> EditPlan {
        guard name.wholeMatch(of: #/[A-Za-z][A-Za-z0-9]*/#) != nil else { throw SochiError.invalidTargetName(name) }
        async let loadedIndex = TemplateIndex.load()
        async let loadedSpecs = XcodeSpecs.load()
        async let toolsVersion = Xcodebuild.version()
        async let fullName = Shell.run(["id", "-F"])
        let resolved = try await resolveTarget(path: path, name: hostName, force: force)
        let (index, specs) = (try await loadedIndex, try await loadedSpecs)
        let template = try index.find(query)
        let file = resolved.file
        let host = resolved.target
        guard file.objectVersion >= 77 else { throw SochiError.legacyProjectFormat(file.objectVersion) }
        let folder = file.projectDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: folder.path) { throw SochiError.pathExists(folder.path) }

        let hostSettings = host.configurations.first.flatMap { resolved.settings[$0.name] } ?? [:]
        let context = TemplateContext(
            name: name,
            projectName: file.projectURL.deletingPathExtension().lastPathComponent,
            hostBundleIdentifier: host.configurations.first?.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
                ?? hostSettings["PRODUCT_BUNDLE_IDENTIFIER"],
            hostProductName: hostSettings["INFOPLIST_KEY_CFBundleDisplayName"] ?? hostSettings["PRODUCT_NAME"] ?? host.name,
            hostProductType: host.productType,
            developmentTeam: hostSettings["DEVELOPMENT_TEAM"],
            options: options,
            fullUserName: (try? await fullName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? NSFullUserName(),
            macroOverrides: templateMacros(project: file.projectURL))
        let engine = TemplateEngine(index: index, specs: specs)
        var output = try engine.instantiate(
            template, context: context, projectSettings: file.projectBuildSettings, configurations: host.configurations.map(\.name))
        if file.targets.contains(where: { $0.name.caseInsensitiveCompare(output.targetName) == .orderedSame }) {
            throw SochiError.targetExists(output.targetName)
        }

        // Align with the host so the new target never silently diverges from the app that embeds it.
        var notes: [String] = []
        for config in host.configurations {
            var settings = output.settings[config.name] ?? [:]
            for key in hostAlignedSettings {
                let hostValue = config.buildSettings[key] as? String ?? resolved.settings[config.name]?[key]
                guard let hostValue, !hostValue.isEmpty else { continue }
                if case .string(let templateValue)? = settings[key], templateValue != hostValue,
                   config.name == host.configurations.first?.name, !["DEVELOPMENT_TEAM", "CODE_SIGN_STYLE"].contains(key) {
                    notes.append("\(key) \(hostValue) from \(host.name) (template default: \(templateValue))")
                }
                settings[key] = .string(hostValue)
            }
            // Xcode's signing UI (not the template) sets the signing style; it defaults to Automatic.
            if settings["CODE_SIGN_STYLE"] == nil { settings["CODE_SIGN_STYLE"] = .string("Automatic") }
            if case .string("latest_iphoneos")? = settings["IPHONEOS_DEPLOYMENT_TARGET"] {
                let sdk = try await Shell.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"])
                settings["IPHONEOS_DEPLOYMENT_TARGET"] = .string(sdk.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            output.settings[config.name] = settings
        }

        var spec = TargetSpec(name: output.targetName, folder: name, productType: output.productType)
        spec.files = output.files
        spec.infoPlist = output.infoPlist
        spec.configurationSettings = output.settings
        spec.frameworks = output.frameworks
        spec.embed = output.embed
        let rendered = try TargetBuilder.render(spec, in: file, host: host, specs: specs, toolsVersion: try await toolsVersion)

        var plan = EditPlan(target: output.targetName, projectURL: file.projectURL)
        plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(rendered.text.utf8)))
        for (relative, contents) in spec.files.sorted(by: { $0.key < $1.key }) {
            plan.edits.append(.init(url: folder.appendingPathComponent(relative), original: nil, updated: contents))
        }
        if let info = spec.infoPlist {
            plan.edits.append(.init(url: folder.appendingPathComponent("Info.plist"), original: nil, updated: info))
        }
        plan.expectedTargets = [output.targetName]
        let chosen = output.resolvedOptions.filter { key, _ in engine.options(of: template).contains { $0.hasPrefix(key) } }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        plan.notes.append("Xcode template \"\(template.name)\" → target \(output.targetName)"
            + (spec.embed ? ", embedded in \(host.name)" : "") + (chosen.isEmpty ? "" : " (\(chosen.joined(separator: ", ")))"))
        plan.notes += notes
        return plan
    }

    /// Settings taken from the host app rather than the template.
    static let hostAlignedSettings = [
        "CODE_SIGN_STYLE", "CURRENT_PROJECT_VERSION", "DEVELOPMENT_TEAM", "IPHONEOS_DEPLOYMENT_TARGET", "MARKETING_VERSION", "SWIFT_VERSION",
    ]

    /// `IDETemplateMacros.plist` overrides, from the project, then the user's Xcode data.
    static func templateMacros(project: URL) -> [String: String] {
        let candidates = [
            project.appendingPathComponent("xcshareddata/IDETemplateMacros.plist"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/UserData/IDETemplateMacros.plist"),
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                return plist
            }
        }
        return [:]
    }

    /// The selected Xcode's target templates with their options, for `sochi templates`.
    public static func listTemplates() async throws -> [(template: XcodeTemplate, options: [String])] {
        async let index = TemplateIndex.load()
        async let specs = XcodeSpecs.load()
        let engine = TemplateEngine(index: try await index, specs: try await specs)
        let all = engine.index.targetTemplates()
        // A MultiPlatform template is hidden when an iOS one has the same name (`find` prefers the iOS one too).
        let visible = all.filter { t in t.platformFolder == "iOS" || !all.contains { $0.name == t.name && $0.platformFolder == "iOS" } }
        return visible.map { ($0, engine.options(of: $0)) }
    }
}
