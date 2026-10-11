import Foundation

/// Per-project memory: choices the user made (or we detected) and what we last installed where.
///
/// Rules that keep this safe:
/// - Only *choices* are remembered (scheme, team). They're validated by xcodebuild on every build, and a
///   stale choice is detected and re-resolved (see `Session.buildResolving`).
/// - Derived facts like build settings are never stored; they're queried fresh each run.
/// - Install records only ever let us *skip* work when content and on-device identity both match.
/// - Unreadable or unknown-version state is treated as empty, never as an error.
public struct ProjectState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = ProjectState.currentVersion
    public var scheme: String?
    public var team: String?
    /// Keyed by device UDID.
    public var installs: [String: InstallRecord] = [:]

    public init() {}

    public static func load(from url: URL) -> ProjectState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ProjectState.self, from: data),
              state.version == currentVersion
        else { return ProjectState() }
        return state
    }

    /// Atomic write, so a crash or a concurrent sochi never leaves a torn file. Failures are non-fatal.
    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// What we installed on a device, and the identity the device gave that copy.
public struct InstallRecord: Codable, Sendable, Equatable {
    public let bundleIdentifier: String
    /// Content hash of the built bundle (see `AppBundle.fingerprint`).
    public let fingerprint: String
    /// The on-device bundle URL. It contains a container UUID that changes on every install by anyone,
    /// so a match proves the device still holds the exact copy we installed.
    public let deviceAppURL: String

    /// Skipping is allowed only when every piece of evidence agrees.
    public func allowsSkipping(bundleIdentifier: String, fingerprint: String?, deviceAppURL: String?) -> Bool {
        guard let fingerprint, let deviceAppURL else { return false }
        return self.bundleIdentifier == bundleIdentifier
            && self.fingerprint == fingerprint
            && self.deviceAppURL == deviceAppURL
    }
}
