import Foundation

/// A target described only by Apple identifiers: no template, no sochi catalog.
public struct GenericTargetRequest: Sendable {
    public var name: String
    /// Full (`com.apple.product-type.app-extension`) or short (`app-extension`) product type.
    public var productType: String
    /// NSExtension / ExtensionKit extension point identifier, for extension product types.
    public var extensionPoint: String?
    public var embed: Bool

    public init(name: String, productType: String, extensionPoint: String?, embed: Bool) {
        self.name = name
        self.productType = productType
        self.extensionPoint = extensionPoint
        self.embed = embed
    }
}

extension ProjectEditor {
    /// Plans a target from Apple identifiers alone. The product type must be one the selected Xcode defines;
    /// how it's embedded comes from Xcode's build specs. Versioning, signing, Swift version and deployment
    /// target follow the host app so the new target never silently diverges from it.
    public static func planGenericTarget(
        _ request: GenericTargetRequest, path: String, host hostName: String?, force: Bool
    ) async throws -> EditPlan {
        let name = request.name
        guard name.wholeMatch(of: #/[A-Za-z][A-Za-z0-9]*/#) != nil else { throw SochiError.invalidTargetName(name) }

        async let loadedSpecs = XcodeSpecs.load()
        async let toolsVersion = Xcodebuild.version()
        let resolved = try await resolveTarget(path: path, name: hostName, force: force)
        let specs = try await loadedSpecs
        let file = resolved.file
        let host = resolved.target
        guard host.isApplication else { throw SochiError.notAnApp(host.name) }
        guard file.objectVersion >= 77 else { throw SochiError.legacyProjectFormat(file.objectVersion) }
        if file.targets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw SochiError.targetExists(name)
        }
        let folder = file.projectDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: folder.path) { throw SochiError.pathExists(folder.path) }

        let productType = try resolveProductType(request.productType, specs: specs)
        let fileType = specs.productFileType(productType) ?? ""
        var spec = TargetSpec(name: name, folder: name, productType: productType)
        spec.embed = request.embed

        // Info.plist keys are Apple's: NSExtension for app extensions, EXAppExtensionAttributes for ExtensionKit.
        let isExtension = ["wrapper.app-extension", "wrapper.extensionkit-extension"].contains(fileType)
        if isExtension, request.extensionPoint == nil { throw SochiError.extensionPointRequired(productType) }
        if !isExtension, request.extensionPoint != nil { throw SochiError.extensionPointNotApplicable(productType) }
        switch fileType {
        case "wrapper.app-extension":
            // Installation requires a principal class (or storyboard), so a placeholder is always generated.
            spec.infoPlist = try plist(["NSExtension": [
                "NSExtensionPointIdentifier": request.extensionPoint!,
                "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).\(name)",
            ]])
            spec.files["\(name).swift"] = Data("""
                import Foundation

                // Principal class for the \(request.extensionPoint!) extension point.
                // Change its superclass and protocols to what that extension point expects.
                final class \(name): NSObject {}

                """.utf8)
        case "wrapper.extensionkit-extension":
            spec.infoPlist = try plist(["EXAppExtensionAttributes": ["EXExtensionPointIdentifier": request.extensionPoint!]])
            spec.files["\(name).swift"] = Data("""
                // Entry point for the \(request.extensionPoint!) extension point.
                // Add the `@main` type that extension point expects (see its framework's documentation).

                """.utf8)
        case "wrapper.application":
            spec.files["\(name)App.swift"] = Data("""
                import SwiftUI

                @main
                struct \(name)App: App {
                    var body: some Scene {
                        WindowGroup {
                            Text("\(name)")
                        }
                    }
                }

                """.utf8)
        default:
            spec.files["\(name).swift"] = Data("// \(name)\n".utf8)
        }

        spec.settings = [
            "PRODUCT_NAME": .string("$(TARGET_NAME)"),
            "GENERATE_INFOPLIST_FILE": .string("YES"),
            "INFOPLIST_KEY_CFBundleDisplayName": .string(name),
            "SWIFT_EMIT_LOC_STRINGS": .string("YES"),
        ]
        if isExtension {
            spec.settings["SKIP_INSTALL"] = .string("YES")
            spec.settings["LD_RUNPATH_SEARCH_PATHS"] = .list(["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])
        } else if fileType == "wrapper.application" {
            spec.settings["LD_RUNPATH_SEARCH_PATHS"] = .list(["$(inherited)", "@executable_path/Frameworks"])
            spec.settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = .string("YES")
            spec.settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = .string("YES")
        }
        for config in host.configurations {
            var settings: [String: TargetSpec.Setting] = [:]
            for key in inheritedHostSettings {
                switch config.buildSettings[key] {
                case let value as String: settings[key] = .string(value)
                case let values as [String]: settings[key] = .list(values)
                default: break
                }
            }
            // Keep the host's literal (variables included) so the two bundle IDs never drift apart.
            let hostBundleID = config.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
                ?? resolved.settings[config.name]?["PRODUCT_BUNDLE_IDENTIFIER"] ?? host.name
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = .string("\(hostBundleID).\(name)")
            spec.configurationSettings[config.name] = settings
        }

        let output = try TargetBuilder.render(spec, in: file, host: host, specs: specs, toolsVersion: try await toolsVersion)
        var plan = EditPlan(target: name, projectURL: file.projectURL)
        plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(output.text.utf8)))
        for (relative, contents) in spec.files.sorted(by: { $0.key < $1.key }) {
            plan.edits.append(.init(url: folder.appendingPathComponent(relative), original: nil, updated: contents))
        }
        if let info = spec.infoPlist {
            plan.edits.append(.init(url: folder.appendingPathComponent("Info.plist"), original: nil, updated: info))
        }
        plan.expectedTargets = [name]
        let embedding = spec.embed ? specs.embedRule(productType).map { "embedded in \(host.name) (\($0.phaseName))" } : nil
        plan.notes.append("\(productType) target \(name)" + (embedding.map { ", \($0)" } ?? ""))
        if fileType == "wrapper.extensionkit-extension" {
            // iOS rejects the whole app install if an ExtensionKit extension has no Swift `@main` entry point,
            // and the right entry type depends on the extension point, which only a template knows.
            plan.notes.append(
                "warning: add the `@main` type \(request.extensionPoint!) expects to \(name)/\(name).swift before installing; "
                    + "iOS refuses to install the app while it's missing")
        }
        return plan
    }

    /// Settings a new target copies from its host so versioning, signing and platform stay aligned.
    static let inheritedHostSettings = [
        "CODE_SIGN_STYLE", "CURRENT_PROJECT_VERSION", "DEVELOPMENT_TEAM", "IPHONEOS_DEPLOYMENT_TARGET",
        "MARKETING_VERSION", "SWIFT_VERSION", "TARGETED_DEVICE_FAMILY",
    ]

    /// Accepts a full product type or its short form; anything the selected Xcode defines is valid.
    static func resolveProductType(_ input: String, specs: XcodeSpecs) throws -> String {
        let candidates = [input, "com.apple.product-type.\(input)"]
        if let match = candidates.first(where: specs.isKnown) { return match }
        let needle = input.lowercased()
        let suggestions = specs.knownProductTypes
            .filter { $0.lowercased().contains(needle) || needle.contains($0.replacingOccurrences(of: "com.apple.product-type.", with: "")) }
            .map { $0.replacingOccurrences(of: "com.apple.product-type.", with: "") }
        throw SochiError.unknownProductType(input, suggestions: Array(suggestions.prefix(5)))
    }

    private static func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}

extension Xcodebuild {
    /// The selected Xcode's marketing version, e.g. `27.0`, as recorded in `CreatedOnToolsVersion`.
    static func version() async throws -> String {
        let output = try await Shell.run(["xcodebuild", "-version"])
        return output.firstMatch(of: #/Xcode (\d+(?:\.\d+)*)/#).map { String($0.1) } ?? "0"
    }
}
