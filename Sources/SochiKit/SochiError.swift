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
            return "Unknown capability '\(name)'. Available: \(available.joined(separator: ", "))"
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
        }
    }
}
