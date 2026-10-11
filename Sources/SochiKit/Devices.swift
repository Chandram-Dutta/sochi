import Foundation

/// A physical device known to CoreDevice (paired, but not necessarily reachable right now).
public struct Device: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let model: String
    public let platform: String
    public let osVersion: String
    /// `connected`, `disconnected` (reachable, tunnel not up yet), or `unavailable` (not reachable).
    public let tunnelState: String
    public let developerModeEnabled: Bool

    /// devicectl brings the tunnel up on demand, so anything not `unavailable` is usable.
    public var isReachable: Bool { tunnelState != "unavailable" }
}

public enum Devices {
    public static func list() async throws -> [Device] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sochi-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        try await Shell.run(["xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", output.path])
        return try parse(Data(contentsOf: output))
    }

    static func parse(_ json: Data) throws -> [Device] {
        struct Entry: Decodable {
            struct Connection: Decodable { let tunnelState: String? }
            struct Properties: Decodable { let name: String?; let osVersionNumber: String?; let developerModeStatus: String? }
            struct Hardware: Decodable {
                let udid: String?; let marketingName: String?; let platform: String?; let reality: String?
            }
            let connectionProperties: Connection
            let deviceProperties: Properties
            let hardwareProperties: Hardware
        }
        struct Output: Decodable { struct Result: Decodable { let devices: [Entry] }; let result: Result }

        return try JSONDecoder().decode(Output.self, from: json).result.devices.compactMap { entry in
            let hw = entry.hardwareProperties
            guard hw.reality == "physical", let udid = hw.udid else { return nil }
            return Device(
                udid: udid,
                name: entry.deviceProperties.name ?? udid,
                model: hw.marketingName ?? "Unknown",
                platform: hw.platform ?? "iOS",
                osVersion: entry.deviceProperties.osVersionNumber ?? "?",
                tunnelState: entry.connectionProperties.tunnelState ?? "unavailable",
                developerModeEnabled: entry.deviceProperties.developerModeStatus == "enabled")
        }
    }

    /// The requested device (name or UDID), else the first reachable one.
    public static func pick(from devices: [Device], requested: String?, platform: String = "iOS") throws -> Device? {
        let pool = devices.filter { $0.platform == platform }
        if let requested {
            return pool.first { $0.udid == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame }
        }
        guard let device = pool.first(where: \.isReachable) else {
            throw SochiError.noDeviceConnected(paired: pool.map(\.name))
        }
        return device
    }

    /// The on-device URL of an installed app, or nil if it isn't installed.
    public static func installedAppURL(_ bundleID: String, on device: Device) async throws -> String? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sochi-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        try await Shell.run([
            "xcrun", "devicectl", "device", "info", "apps", "--device", device.udid,
            "--bundle-id", bundleID, "--quiet", "--json-output", output.path,
        ])
        return try parseInstalledAppURL(Data(contentsOf: output), bundleID: bundleID)
    }

    static func parseInstalledAppURL(_ json: Data, bundleID: String) throws -> String? {
        struct App: Decodable { let bundleIdentifier: String; let url: String? }
        struct Output: Decodable { struct Result: Decodable { let apps: [App] }; let result: Result }
        return try JSONDecoder().decode(Output.self, from: json).result.apps
            .first { $0.bundleIdentifier == bundleID }?.url
    }

    public static func install(_ app: URL, on device: Device) async throws {
        try await Shell.run(["xcrun", "devicectl", "device", "install", "app", "--device", device.udid, app.path])
    }

    /// Launches with the app's stdout bridged to ours. devicectl forwards ctrl-c to the app and waits for it to exit.
    public static func launchAttached(_ bundleID: String, on device: Device) async throws -> Int32 {
        try await Shell.exec([
            "xcrun", "devicectl", "device", "process", "launch",
            "--console", "--terminate-existing", "--device", device.udid, bundleID,
        ])
    }
}
