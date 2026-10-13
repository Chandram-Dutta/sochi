import Foundation

public enum SochiError: Error, CustomStringConvertible {
    case noProject(URL)
    case swiftPackageOnly(URL)
    case ambiguousProject([URL])
    case notFound(String)
    case noSchemes(String)
    case unknownScheme(String, available: [String])
    case noSimulator(platform: String)
    case unknownDevice(String)
    case noAppTarget(scheme: String)
    case unexpectedOutput(command: String)
    case noDeviceConnected(paired: [String])
    case noSigningTeam
    case ambiguousTeam([Team])
    case productMismatch(String)
    case unreadableProject(String)
    case editVerificationFailed(String)
    case unknownCapability(String, available: [String])
    case invalidCapabilityValue(String, String)
    case unknownTarget(String, available: [String])
    case ambiguousTarget([String])
    case generatedProject(String)
    case mixedEntitlements(target: String, missing: [String])
    case invalidTargetName(String)
    case extensionPointRequired(String)
    case extensionPointNotApplicable(String)
    case notAnApp(String)
    case legacyProjectFormat(Int)
    case targetExists(String)
    case pathExists(String)
    case xcodeDataUnavailable(String)
    case notAnArray(String)
    case ambiguousCapability(String, candidates: [String])
    case capabilityNeedsValue(capability: String, key: String, hint: String?, documentation: String?)
    case capabilityNeedsChoice(capability: String, key: String, options: [String])
    case capabilityHasNoEntitlements(String)
    case capabilityUnsupported(String, String)
    case unknownTemplate(String)
    case ambiguousTemplate(String, candidates: [String])
    case unsupportedTemplate(String, String)
    case templateNeedsHost(String)
    case unknownTemplateOption(String, available: [String])
    case unsupportedTemplateMacro(String)
    case unknownProductType(String, suggestions: [String])
    case noEmbedRule(String)

    public var description: String {
        switch self {
        case .noProject(let dir):
            return "No .xcodeproj or .xcworkspace found in \(dir.path)"
        case .swiftPackageOnly(let dir):
            return "\(dir.path) is a Swift package. Only Xcode projects and workspaces are supported for now."
        case .ambiguousProject(let urls):
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            return "Found several projects (\(names)). Pass one explicitly, e.g. `sochi run \(urls[0].lastPathComponent)`"
        case .notFound(let path):
            return "No such file or directory: \(path)"
        case .noSchemes(let name):
            return "\(name) has no schemes"
        case .unknownScheme(let scheme, let available):
            return "No scheme named '\(scheme)'. Available: \(available.joined(separator: ", "))"
        case .noSimulator(let platform):
            return "No available \(platform) simulators. Install a runtime in Xcode › Settings › Components."
        case .unknownDevice(let query):
            return "No simulator matches '\(query)'. Run `sochi sims` to list them."
        case .noAppTarget(let scheme):
            return "Scheme '\(scheme)' doesn't build an application"
        case .unexpectedOutput(let command):
            return "Couldn't parse output of `\(command)`"
        case .noDeviceConnected(let paired):
            let known = paired.isEmpty ? "" : " (paired: \(paired.joined(separator: ", ")))"
            return "No device connected\(known). Plug in and unlock your device, or pass --sim to use a simulator."
        case .noSigningTeam:
            return "The project has no development team and no accounts are signed into Xcode. Add one in Xcode › Settings › Accounts."
        case .ambiguousTeam(let teams):
            let list = teams.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
            return "The project has no development team. Choose one with --team or SOCHI_TEAM: \(list)"
        case .productMismatch(let detail):
            return "Refusing to install: \(detail). Try `--fresh`, or report this as a sochi bug."
        case .unreadableProject(let path):
            return "Couldn't read \(path)"
        case .editVerificationFailed(let detail):
            return "Edit didn't verify (\(detail)). No files were changed."
        case .unknownCapability(let name, let available):
            return available.isEmpty
                ? "No capability matches '\(name)'. Run `sochi capabilities --all` to list them."
                : "Unknown capability '\(name)'. Available: \(available.joined(separator: ", "))"
        case .invalidCapabilityValue(let name, let reason):
            return "\(name) \(reason)"
        case .unknownTarget(let name, let available):
            return "No target named '\(name)'. Available: \(available.joined(separator: ", "))"
        case .ambiguousTarget(let targets):
            return "Several targets could be meant (\(targets.joined(separator: ", "))). Pick one with --target."
        case .generatedProject(let marker):
            return "This project looks generated (found \(marker)). Edit the generator's manifest instead, or pass --force to edit the .xcodeproj anyway."
        case .mixedEntitlements(let target, let missing):
            return "\(target) has an entitlements file in some configurations but not \(missing.joined(separator: ", ")). Set CODE_SIGN_ENTITLEMENTS for those first so sochi doesn't guess."
        case .invalidTargetName(let name):
            return "'\(name)' isn't a valid target name. Use letters and digits, starting with a letter (it becomes a Swift type name)."
        case .extensionPointRequired(let type):
            return "\(type) targets need an extension point, e.g. --point com.apple.widgetkit-extension"
        case .extensionPointNotApplicable(let type):
            return "--point only applies to extension targets, not \(type)"
        case .notAnApp(let name):
            return "\(name) isn't an app target, so it can't host an extension. Pick the app with --target."
        case .legacyProjectFormat(let version):
            return "This project uses the pre-Xcode 16 format (objectVersion \(version)), with groups instead of folders. sochi can only add targets to folder-based projects for now."
        case .targetExists(let name):
            return "A target named \(name) already exists"
        case .pathExists(let path):
            return "\(path) already exists; pick another name or move it"
        case .capabilityNeedsValue(let capability, let key, let hint, let documentation):
            return "\(capability) needs a value for \(key)\(hint.map { " (\($0))" } ?? ""). Pass it after the name: sochi add capability \(capability) <value>"
                + (documentation.map { "\n  Format: \($0)" } ?? "")
        case .capabilityNeedsChoice(let capability, let key, let options):
            return "\(capability) needs you to choose for \(key): \(options.joined(separator: ", ")). E.g. sochi add capability \(capability) \(options.first ?? "<value>")"
        case .capabilityHasNoEntitlements(let name):
            return "\(name) has no entitlements to write; it's enabled on Apple's side only (automatic signing handles it)"
        case .capabilityUnsupported(let name, let reason):
            return "\(name): \(reason)"
        case .unknownTemplate(let query):
            return "No target template matches '\(query)'. Run `sochi templates` to list them."
        case .ambiguousTemplate(let query, let candidates):
            return "'\(query)' matches several templates: \(candidates.joined(separator: ", ")). Use the full name."
        case .unsupportedTemplate(let name, let reason):
            return "sochi can't run the \(name) template yet: \(reason). Use `sochi add target <Name> --type …` instead."
        case .templateNeedsHost(let name):
            return "The \(name) template embeds in an app; pass the app with --host"
        case .unknownTemplateOption(let option, let available):
            return "Unknown option '\(option)'." + (available.isEmpty ? " This template has no options." : " Options: \(available.joined(separator: ", "))")
        case .unsupportedTemplateMacro(let name):
            return "The template uses a macro sochi doesn't know (___\(name)___); no files were written."
        case .ambiguousCapability(let query, let candidates):
            return "'\(query)' matches several capabilities: \(candidates.joined(separator: ", ")). Use the full name."
        case .notAnArray(let key):
            return "\(key) isn't an array entitlement; use `sochi entitlements set` instead"
        case .xcodeDataUnavailable(let what):
            return "Couldn't read \(what) from the selected Xcode (`xcode-select -p`). Is it a full Xcode install?"
        case .unknownProductType(let type, let suggestions):
            let hint = suggestions.isEmpty ? "" : " Did you mean: \(suggestions.joined(separator: ", "))?"
            return "The selected Xcode doesn't define product type '\(type)'.\(hint)"
        case .noEmbedRule(let type):
            return "Xcode doesn't embed '\(type)' products in an app, so sochi won't wire it into one. Create it with --no-embed."
        }
    }
}
