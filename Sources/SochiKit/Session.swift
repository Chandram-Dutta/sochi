import Foundation

/// Where the app runs. Physical devices are the default; simulators are opt-in.
public enum Destination: Sendable, Equatable {
    case device(Device)
    case simulator(Simulator)

    public var name: String {
        switch self {
        case .device(let d): d.name
        case .simulator(let s): s.name
        }
    }

    public var summary: String {
        switch self {
        case .device(let d): "\(d.name) (\(d.model), \(d.platform) \(d.osVersion))"
        case .simulator(let s): "\(s.name) (\(s.runtime) simulator)"
        }
    }

    var xcodebuildDestination: String {
        switch self {
        case .device(let d): "platform=\(d.platform),id=\(d.udid)"
        case .simulator(let s): "platform=\(s.runtime.platform) Simulator,id=\(s.udid)"
        }
    }

    /// `DTPlatformName` a correct build for this destination carries in its Info.plist.
    var sdkPlatformName: String {
        let base: String
        switch self {
        case .device(let d): base = d.platform
        case .simulator(let s): base = s.runtime.platform
        }
        let os = ["iOS": "iphone", "tvOS": "appletv", "watchOS": "watch", "xrOS": "xr", "visionOS": "xr"][base] ?? base.lowercased()
        return isDevice ? "\(os)os" : "\(os)simulator"
    }

    public var isDevice: Bool {
        if case .device = self { return true }
        return false
    }
}

/// Where a choice came from. Shown to the user so remembered values never act invisibly.
public enum ChoiceSource: Sendable, Equatable {
    case explicit, saved, detected
}

/// One project + scheme + destination. Everything the CLI (and later the daemon) does goes through a session.
public struct Session: Sendable {
    public let project: XcodeProject
    public private(set) var scheme: String
    public private(set) var schemeSource: ChoiceSource
    public let configuration: String
    public let destination: Destination
    /// Overrides the project's `DEVELOPMENT_TEAM` when set; nil means "use the project's own".
    public private(set) var developmentTeam: String?
    public private(set) var teamSource: ChoiceSource?
    /// When set, shortcuts are disabled for this run: the app is always reinstalled.
    /// Remembered choices still apply; they're user intent, not a cache.
    public let fresh: Bool
    private var state: ProjectState

    /// Resolves a session with zero config: finds the project, its app scheme, and a destination.
    /// Without `simulator`, a connected device is required; `device` may name a device or, as an escape hatch, a simulator.
    /// `team` may be an ID, a team name, or `auto` to forget a saved team.
    public static func resolve(
        path: String, scheme: String?, device: String?, simulator: Bool, configuration: String,
        team: String?, fresh: Bool
    ) async throws -> Session {
        let project = try XcodeProject.locate(path)
        let saved = ProjectState.load(from: Paths.projectState(for: project))
        async let destination = resolveDestination(requested: device, simulator: simulator)

        let resolvedScheme: (String, ChoiceSource)
        if let scheme {
            resolvedScheme = (scheme, .explicit)
        } else if let savedScheme = saved.scheme {
            resolvedScheme = (savedScheme, .saved)
        } else {
            resolvedScheme = (try await detectScheme(project), .detected)
        }

        var resolvedTeam: (String, ChoiceSource)?
        var state = saved
        if let team, team.lowercased() == "auto" {
            state.team = nil
        } else if let team {
            let teams = (try? await Signing.teams()) ?? []
            resolvedTeam = (try Signing.resolveTeam(requested: team, projectTeam: nil, available: teams) ?? team, .explicit)
        } else if let savedTeam = saved.team {
            resolvedTeam = (savedTeam, .saved)
        }

        return Session(
            project: project, scheme: resolvedScheme.0, schemeSource: resolvedScheme.1,
            configuration: configuration, destination: try await destination,
            developmentTeam: resolvedTeam?.0, teamSource: resolvedTeam?.1, fresh: fresh, state: state)
    }

    private static func detectScheme(_ project: XcodeProject) async throws -> String {
        try Xcodebuild.pickScheme(try await Xcodebuild.schemes(for: project), project: project, requested: nil)
    }

    private static func resolveDestination(requested: String?, simulator: Bool) async throws -> Destination {
        if simulator {
            return .simulator(try Simulators.pick(from: try await Simulators.list(), requested: requested))
        }
        if let device = try Devices.pick(from: try await Devices.list(), requested: requested) {
            return .device(device)
        }
        // A name that matched no physical device: allow an explicitly named simulator.
        if let requested, let sim = try? Simulators.pick(from: try await Simulators.list(), requested: requested) {
            return .simulator(sim)
        }
        throw SochiError.unknownDevice(requested ?? "")
    }

    /// Our own DerivedData per project, so we never fight Xcode's and can find build logs deterministically.
    public var derivedDataURL: URL { Paths.projectCache(for: project).appendingPathComponent("DerivedData") }

    var settingsArguments: [String] {
        project.xcodebuildArguments + [
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination.xcodebuildDestination,
            "-derivedDataPath", derivedDataURL.path,
        ]
    }

    var buildArguments: [String] {
        var args = settingsArguments
        if destination.isDevice { args += ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"] }
        if let developmentTeam { args.append("DEVELOPMENT_TEAM=\(developmentTeam)") }
        return args
    }

    /// Builds once with the current choices. Returns whether the build succeeded.
    public func build(onEvent: @escaping @Sendable (BuildEvent) -> Void) async throws -> Bool {
        let status = try await Shell.stream(["xcodebuild", "build"] + buildArguments, cwd: project.directory) {
            onEvent(BuildLog.parse($0))
        }
        return status == 0
    }

    /// Builds, recovering from failures caused by a stale or missing choice:
    /// a saved scheme that no longer exists is re-detected, and a missing signing team is filled in
    /// when exactly one is available. Each recovery happens at most once. Choices that produced a
    /// successful build are saved for next time.
    ///
    /// `isRecoverable` lets the caller hold back diagnostics that a retry may make moot.
    public mutating func buildResolving(
        onEvent: @escaping @Sendable (BuildEvent) -> Void,
        onRetry: @Sendable (String) -> Void
    ) async throws -> Bool {
        var recovered = Set<String>()
        while true {
            let failures = Box<[BuildFailure]>([])
            let ok = try await build { event in
                if case .diagnostic(let d) = event, case let f = BuildFailure.classify(d), f != .other {
                    failures.value.append(f)
                }
                onEvent(event)
            }
            if ok {
                saveChoices()
                return true
            }
            if failures.value.contains(.missingScheme), schemeSource == .saved, recovered.insert("scheme").inserted {
                onRetry("saved scheme '\(scheme)' no longer exists, detecting again")
                scheme = try await Self.detectScheme(project)
                schemeSource = .detected
            } else if failures.value.contains(.needsTeam), developmentTeam == nil, recovered.insert("team").inserted {
                let team = try Signing.resolveTeam(requested: nil, projectTeam: nil, available: try await Signing.teams())!
                onRetry("project has no development team, signing with \(team)")
                developmentTeam = team
                teamSource = .detected
            } else {
                return false
            }
        }
    }

    /// True when a failed build's diagnostic may be resolved by `buildResolving`'s retry, given current choices.
    public func isRecoverable(_ diagnostic: Diagnostic) -> Bool {
        switch BuildFailure.classify(diagnostic) {
        case .missingScheme: schemeSource == .saved
        case .needsTeam: developmentTeam == nil
        case .other: false
        }
    }

    private mutating func saveChoices() {
        state.scheme = scheme
        if let developmentTeam { state.team = developmentTeam }
        state.save(to: Paths.projectState(for: project))
    }

    public func appProduct() async throws -> AppProduct {
        try await Xcodebuild.appProduct(arguments: settingsArguments, scheme: scheme)
    }

    /// Gets the destination ready to receive an install (boots a simulator; devices need nothing).
    public func prepare() async throws {
        if case .simulator(let sim) = destination { try await Simulators.boot(sim) }
    }

    public enum InstallOutcome: Sendable, Equatable {
        case installed
        /// The device already holds this exact build, installed by us.
        case upToDate
    }

    /// Verifies the built bundle, then installs it unless the device provably already has this exact copy.
    public mutating func installIfNeeded(_ product: AppProduct) async throws -> InstallOutcome {
        try AppBundle.verify(product, for: destination)
        switch destination {
        case .simulator(let s):
            try await Simulators.install(product.appURL, on: s)
            return .installed
        case .device(let d):
            let fingerprint = AppBundle.fingerprint(product.appURL)
            if !fresh, let record = state.installs[d.udid] {
                let onDevice = try? await Devices.installedAppURL(product.bundleIdentifier, on: d)
                if record.allowsSkipping(bundleIdentifier: product.bundleIdentifier, fingerprint: fingerprint, deviceAppURL: onDevice) {
                    return .upToDate
                }
            }
            state.installs[d.udid] = nil
            state.save(to: Paths.projectState(for: project))
            try await Devices.install(product.appURL, on: d)
            if let fingerprint, let onDevice = try? await Devices.installedAppURL(product.bundleIdentifier, on: d) {
                state.installs[d.udid] = InstallRecord(
                    bundleIdentifier: product.bundleIdentifier, fingerprint: fingerprint, deviceAppURL: onDevice)
                state.save(to: Paths.projectState(for: project))
            }
            return .installed
        }
    }

    /// Launches with app output attached to ours; returns when the app exits or is interrupted.
    public func launchAttached(_ product: AppProduct) async throws -> Int32 {
        switch destination {
        case .device(let d):
            return try await Devices.launchAttached(product.bundleIdentifier, on: d)
        case .simulator(let s):
            let status = try await Simulators.launchAttached(product.bundleIdentifier, on: s)
            await Simulators.terminate(product.bundleIdentifier, on: s)
            return status
        }
    }
}

public enum Paths {
    public static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.sochi")
    }

    /// Remembered choices live outside Caches so the OS doesn't purge them.
    public static var stateRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.sochi")
    }

    /// `~/Library/Caches/dev.sochi/projects/<id>`, for rebuildable artifacts.
    public static func projectCache(for project: XcodeProject) -> URL {
        cacheRoot.appendingPathComponent("projects").appendingPathComponent(projectID(project))
    }

    /// `~/Library/Application Support/dev.sochi/projects/<id>/state.json`
    public static func projectState(for project: XcodeProject) -> URL {
        stateRoot.appendingPathComponent("projects").appendingPathComponent(projectID(project))
            .appendingPathComponent("state.json")
    }

    /// Stable per project: the symlink-resolved path, so /tmp vs /private/tmp (or a linked folder) is one project.
    static func projectID(_ project: XcodeProject) -> String {
        "\(project.name)-\(fnv1a(project.url.resolvingSymlinksInPath().path))"
    }

    /// Stable across runs, unlike `hashValue`.
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
