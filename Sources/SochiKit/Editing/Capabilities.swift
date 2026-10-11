import Foundation

/// A capability expressed as the entitlements it writes. Portal-side setup (App ID capabilities,
/// group/container registration, profiles) is left to Xcode's automatic signing at build time.
public struct Capability: Sendable {
    public enum Values: Sendable {
        /// No values: the entitlement is fixed.
        case none
        /// Values are optional; with none given, `defaultValue` derives one from the bundle ID.
        case optional
        /// At least one value is required.
        case required
    }

    public let name: String
    public let title: String
    public let values: Values
    /// Shown in help, e.g. what a value looks like.
    public let hint: String?
    /// Entitlement keys this capability owns, for detection and removal.
    public let keys: [String]
    let fixed: [String: PlistValue]
    let listKey: String?
    let defaultValue: (@Sendable (_ bundleID: String) -> String)?
    let normalize: @Sendable (String) throws -> String

    /// The entitlements to merge in for the given user values.
    func entries(values: [String], bundleID: String) throws -> [String: PlistValue] {
        var entries = fixed
        guard let listKey else {
            if !values.isEmpty { throw SochiError.invalidCapabilityValue(name, "takes no values") }
            return entries
        }
        var list = try values.map(normalize)
        if list.isEmpty, let defaultValue { list = [defaultValue(bundleID)] }
        if list.isEmpty { throw SochiError.invalidCapabilityValue(name, "needs at least one value, e.g. \(hint ?? "…")") }
        entries[listKey] = .array(list)
        return entries
    }
}

/// The subset of plist values entitlements use; Sendable, unlike `Any`.
enum PlistValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case array([String])

    var object: Any {
        switch self {
        case .bool(let b): b
        case .string(let s): s
        case .array(let a): a
        }
    }
}

public enum Capabilities {
    public static let all: [Capability] = [
        Capability(
            name: "push", title: "Push Notifications", values: .none, hint: nil,
            keys: ["aps-environment"], fixed: ["aps-environment": .string("development")],
            listKey: nil, defaultValue: nil, normalize: { $0 }),
        Capability(
            name: "app-groups", title: "App Groups", values: .optional, hint: "group.com.example.shared",
            keys: ["com.apple.security.application-groups"], fixed: [:],
            listKey: "com.apple.security.application-groups", defaultValue: { "group.\($0)" },
            normalize: { value in
                guard value.hasPrefix("group.") else {
                    throw SochiError.invalidCapabilityValue("app-groups", "'\(value)' must start with 'group.'")
                }
                return value
            }),
        Capability(
            name: "associated-domains", title: "Associated Domains", values: .required, hint: "applinks:example.com",
            keys: ["com.apple.developer.associated-domains"], fixed: [:],
            listKey: "com.apple.developer.associated-domains", defaultValue: nil,
            normalize: { value in
                let services = ["applinks:", "webcredentials:", "activitycontinuation:", "appclips:"]
                guard services.contains(where: value.hasPrefix) else {
                    throw SochiError.invalidCapabilityValue(
                        "associated-domains", "'\(value)' must start with one of \(services.joined(separator: ", "))")
                }
                return value
            }),
        Capability(
            name: "keychain-sharing", title: "Keychain Sharing", values: .optional, hint: "com.example.shared",
            keys: ["keychain-access-groups"], fixed: [:],
            listKey: "keychain-access-groups", defaultValue: { "$(AppIdentifierPrefix)\($0)" },
            normalize: { $0.hasPrefix("$(AppIdentifierPrefix)") ? $0 : "$(AppIdentifierPrefix)\($0)" }),
        Capability(
            name: "sign-in-with-apple", title: "Sign in with Apple", values: .none, hint: nil,
            keys: ["com.apple.developer.applesignin"], fixed: ["com.apple.developer.applesignin": .array(["Default"])],
            listKey: nil, defaultValue: nil, normalize: { $0 }),
        Capability(
            name: "healthkit", title: "HealthKit", values: .none, hint: nil,
            keys: ["com.apple.developer.healthkit", "com.apple.developer.healthkit.access"],
            fixed: ["com.apple.developer.healthkit": .bool(true), "com.apple.developer.healthkit.access": .array([])],
            listKey: nil, defaultValue: nil, normalize: { $0 }),
        Capability(
            name: "time-sensitive-notifications", title: "Time Sensitive Notifications", values: .none, hint: nil,
            keys: ["com.apple.developer.usernotifications.time-sensitive"],
            fixed: ["com.apple.developer.usernotifications.time-sensitive": .bool(true)],
            listKey: nil, defaultValue: nil, normalize: { $0 }),
        Capability(
            name: "wifi-info", title: "Access Wi-Fi Information", values: .none, hint: nil,
            keys: ["com.apple.developer.networking.wifi-info"],
            fixed: ["com.apple.developer.networking.wifi-info": .bool(true)],
            listKey: nil, defaultValue: nil, normalize: { $0 }),
    ]

    static let aliases = ["push-notifications": "push", "app-group": "app-groups", "siwa": "sign-in-with-apple",
                          "keychain": "keychain-sharing", "associated-domain": "associated-domains"]

    public static func named(_ name: String) throws -> Capability {
        let key = aliases[name.lowercased()] ?? name.lowercased()
        guard let capability = all.first(where: { $0.name == key }) else {
            throw SochiError.unknownCapability(name, available: all.map(\.name))
        }
        return capability
    }

    /// Merges a capability into an entitlements dictionary. Lists are unioned, preserving existing order.
    static func adding(_ entries: [String: PlistValue], to entitlements: [String: Any]) -> [String: Any] {
        var result = entitlements
        for (key, value) in entries {
            if case .array(let new) = value, let existing = result[key] as? [String] {
                result[key] = existing + new.filter { !existing.contains($0) }
            } else {
                result[key] = value.object
            }
        }
        return result
    }

    /// Removes a capability: specific list values if given, otherwise all of its keys.
    static func removing(_ capability: Capability, values: [String], from entitlements: [String: Any]) throws -> [String: Any] {
        var result = entitlements
        guard !values.isEmpty, let listKey = capability.listKey else {
            capability.keys.forEach { result[$0] = nil }
            return result
        }
        let doomed = try values.map(capability.normalize)
        let remaining = (result[listKey] as? [String] ?? []).filter { !doomed.contains($0) }
        result[listKey] = remaining.isEmpty ? nil : remaining
        return result
    }

    /// Which catalog capabilities an entitlements dictionary enables, plus keys sochi doesn't know.
    public static func detect(in entitlements: [String: Any]) -> (known: [(Capability, [String])], unknown: [String]) {
        var known: [(Capability, [String])] = []
        var claimed = Set<String>()
        for capability in all where capability.keys.contains(where: { entitlements[$0] != nil }) {
            claimed.formUnion(capability.keys)
            known.append((capability, capability.listKey.flatMap { entitlements[$0] as? [String] } ?? []))
        }
        return (known, entitlements.keys.filter { !claimed.contains($0) }.sorted())
    }
}
