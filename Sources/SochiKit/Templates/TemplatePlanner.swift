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
        let file = resolved.file
        let host = resolved.target
        // A watch app hosts watchOS templates; everything else is iOS.
        let hostSDK = resolved.settings[host.configurations.first?.name ?? ""]?["SDKROOT"] ?? "iphoneos"
        let template = try index.find(query, platformFolder: hostSDK.hasPrefix("watch") ? "watchOS" : "iOS")
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
        let outputs = try engine.instantiate(
            template, context: context, projectSettings: file.projectBuildSettings, configurations: host.configurations.map(\.name))

        // Create targets in order, re-reading the project after each so components can embed into earlier ones.
        var current = file
        var created: [String: String] = [:]  // template target identifier → new target ID
        var plan = EditPlan(target: outputs[0].targetName, projectURL: file.projectURL)
        var newFiles: [(URL, Data)] = []
        var notes: [String] = []
        let version = try await toolsVersion
        for var output in outputs {
            if current.targets.contains(where: { $0.name.caseInsensitiveCompare(output.targetName) == .orderedSame }) {
                throw SochiError.targetExists(output.targetName)
            }
            let folder = file.projectDirectory.appendingPathComponent(output.productName)
            if FileManager.default.fileExists(atPath: folder.path) { throw SochiError.pathExists(folder.path) }

            // The new target's own platform (a watch app inside an iOS app is watchOS).
            let sdk: String = {
                if case .string(let value)? = output.settings[host.configurations.first?.name ?? ""]?["SDKROOT"] { return value }
                return hostSDK
            }()
            for config in host.configurations {
                var settings = output.settings[config.name] ?? [:]
                for key in hostAlignedSettings where key != "IPHONEOS_DEPLOYMENT_TARGET" || sdk.hasPrefix("iphone") {
                    let hostValue = config.buildSettings[key] as? String ?? resolved.settings[config.name]?[key]
                    guard let hostValue, !hostValue.isEmpty else { continue }
                    if case .string(let templateValue)? = settings[key], templateValue != hostValue,
                       config.name == host.configurations.first?.name, !["DEVELOPMENT_TEAM", "CODE_SIGN_STYLE"].contains(key) {
                        notes.append("\(output.targetName): \(key) \(hostValue) from \(host.name) (template default: \(templateValue))")
                    }
                    settings[key] = .string(hostValue)
                }
                // Xcode's signing UI (not the template) sets the signing style; it defaults to Automatic.
                if settings["CODE_SIGN_STYLE"] == nil { settings["CODE_SIGN_STYLE"] = .string("Automatic") }
                // `latest_<sdk>` means the installed SDK's version.
                for (key, value) in settings {
                    guard case .string(let raw) = value, raw.hasPrefix("latest_") else { continue }
                    let installed = try await Shell.run(["xcrun", "--sdk", String(raw.dropFirst("latest_".count)), "--show-sdk-version"])
                    settings[key] = .string(installed.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                output.settings[config.name] = settings
            }

            // Where it embeds: a sibling this template created, else the host app if the template is hosted.
            var embedHost: PBXProjectFile.Target? = nil
            if let injection = output.injectInto {
                guard let siblingID = created[injection], let sibling = current.targets.first(where: { $0.id == siblingID }) else {
                    throw SochiError.unsupportedTemplate(template.name, "a component embeds into a target it didn't create")
                }
                embedHost = sibling
            } else if output.embed || (output.isComponent && index.resolve(template).association != nil) {
                embedHost = host
            }

            // A watch app embedded in an iOS app is its companion. Xcode sets this in code, not in the template.
            if sdk.hasPrefix("watch"), let embedHost, embedHost.id == host.id, !hostSDK.hasPrefix("watch"),
               let companion = context.hostBundleIdentifier {
                for config in host.configurations where output.settings[config.name]?["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] == nil {
                    output.settings[config.name, default: [:]]["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] = .string(companion)
                }
                notes.append("\(output.targetName): companion of \(host.name) (WKCompanionAppBundleIdentifier \(companion))")
            }

            var spec = TargetSpec(name: output.targetName, folder: output.productName, productType: output.productType)
            spec.files = output.files
            spec.infoPlist = output.infoPlist
            spec.configurationSettings = output.settings
            spec.frameworks = output.frameworks
            spec.embed = embedHost != nil
            spec.sdk = sdk
            let rendered = try TargetBuilder.render(spec, in: current, host: embedHost ?? host, specs: specs, toolsVersion: version)
            current = try PBXProjectFile(projectURL: file.projectURL, text: rendered.text)
            if let identifier = output.targetIdentifier { created[identifier] = rendered.targetID }

            for (relative, contents) in spec.files.sorted(by: { $0.key < $1.key }) { newFiles.append((folder.appendingPathComponent(relative), contents)) }
            if let info = spec.infoPlist { newFiles.append((folder.appendingPathComponent("Info.plist"), info)) }
            plan.expectedTargets.append(output.targetName)
            let chosen = output.isComponent ? [] : output.resolvedOptions.filter { key, _ in engine.options(of: template).contains { $0.hasPrefix(key) } }
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            plan.notes.append((output.isComponent ? "  + target \(output.targetName)" : "Xcode template \"\(template.name)\" → target \(output.targetName)")
                + (embedHost.map { ", embedded in \($0.name)" } ?? "") + (chosen.isEmpty ? "" : " (\(chosen.joined(separator: ", ")))"))
        }

        plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(current.text.utf8)))
        for (url, contents) in newFiles { plan.edits.append(.init(url: url, original: nil, updated: contents)) }
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
        let visible = all.filter { t in t.platformFolder != "MultiPlatform" || !all.contains { $0.name == t.name && $0.platformFolder == "iOS" } }
        return visible.map { ($0, engine.options(of: $0)) }
    }
}
