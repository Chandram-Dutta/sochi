import Foundation

public struct Runtime: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let identifier: String
    public let platform: String
    public let version: [Int]

    /// Parses identifiers like `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    public init(identifier: String) {
        self.identifier = identifier
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        let parts = tail.split(separator: "-")
        platform = parts.first.map(String.init) ?? tail
        version = parts.dropFirst().compactMap { Int($0) }
    }

    public var description: String {
        "\(platform) \(version.map(String.init).joined(separator: "."))"
    }

    public static func < (lhs: Runtime, rhs: Runtime) -> Bool {
        lhs.version.lexicographicallyPrecedes(rhs.version)
    }
}

public struct Simulator: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtime: Runtime

    public var isBooted: Bool { state == "Booted" }
}

public enum Simulators {
    public static func list() async throws -> [Simulator] {
        try parse(Data(try await Shell.run(["xcrun", "simctl", "list", "devices", "available", "-j"]).utf8))
    }

    static func parse(_ json: Data) throws -> [Simulator] {
        struct Device: Decodable { let udid: String; let name: String; let state: String }
        struct List: Decodable { let devices: [String: [Device]] }
        let list = try JSONDecoder().decode(List.self, from: json)
        return list.devices
            .map { (Runtime(identifier: $0.key), $0.value) }
            .sorted { $0.0 > $1.0 }
            .flatMap { runtime, devices in
                devices.map { Simulator(udid: $0.udid, name: $0.name, state: $0.state, runtime: runtime) }
            }
    }

    /// Chooses a simulator: the requested one (name or UDID), else a booted one, else the newest iPhone Pro.
    /// `simulators` is expected newest-runtime-first, as `list()` returns it.
    public static func pick(from simulators: [Simulator], requested: String?, platform: String = "iOS") throws -> Simulator {
        let pool = simulators.filter { $0.runtime.platform == platform }
        if let requested {
            if let match = pool.first(where: { $0.udid == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame }) {
                return match
            }
            throw SochiError.unknownDevice(requested)
        }
        if let booted = pool.first(where: \.isBooted) { return booted }
        guard let newest = pool.first?.runtime else { throw SochiError.noSimulator(platform: platform) }
        let latest = pool.filter { $0.runtime == newest }
        return latest.first { $0.name.hasPrefix("iPhone") && $0.name.hasSuffix(" Pro") }
            ?? latest.first { $0.name.hasPrefix("iPhone") }
            ?? latest[0]
    }

    /// Boots (if needed) and brings up Simulator.app without stealing focus.
    /// Avoids `bootstatus -b`, which was seen hanging indefinitely on an already-booted device (Xcode 27.0).
    public static func boot(_ simulator: Simulator) async throws {
        if !simulator.isBooted {
            try await Shell.run(["xcrun", "simctl", "boot", simulator.udid])
        }
        try await Shell.run(["open", "-g", "-a", "Simulator", "--args", "-CurrentDeviceUDID", simulator.udid])
    }

    public static func install(_ app: URL, on simulator: Simulator) async throws {
        try await Shell.run(["xcrun", "simctl", "install", simulator.udid, app.path])
    }

    /// Launches the app with its stdout/stderr attached to ours. Returns when the app exits or we're interrupted.
    public static func launchAttached(_ bundleID: String, on simulator: Simulator) async throws -> Int32 {
        try await Shell.exec([
            "xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", simulator.udid, bundleID,
        ])
    }

    public static func terminate(_ bundleID: String, on simulator: Simulator) async {
        _ = try? await Shell.run(["xcrun", "simctl", "terminate", simulator.udid, bundleID])
    }
}
