import Foundation

/// The subset of plist values entitlements use; Sendable, unlike `Any`.
public enum PlistValue: Sendable, Equatable {
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

/// A capability sochi can apply: one from Apple's catalog, or one of the few that exist only in Xcode's code.
public enum ResolvedCapability: Sendable {
    case catalog(CapabilityCatalog.Capability)
    case local(LocalCapability)

    public var name: String {
        switch self {
        case .catalog(let c): c.name
        case .local(let l): l.name
        }
    }
}

/// Capabilities Xcode implements in code rather than in its catalog. Deliberately tiny; everything else is data.
public struct LocalCapability: Sendable {
    public let slug: String
    public let name: String
    /// The entitlement it edits, or nil when it isn't supported yet (with `unsupportedReason`).
    public let key: String?
    let unsupportedReason: String?
    let defaultValue: (@Sendable (_ bundleID: String) -> String)?
    let normalize: @Sendable (String) -> String

    public static let all: [LocalCapability] = [
        LocalCapability(
            slug: "keychain-sharing", name: "Keychain Sharing", key: "keychain-access-groups", unsupportedReason: nil,
            defaultValue: { "$(AppIdentifierPrefix)\($0)" },
            normalize: { $0.hasPrefix("$(") ? $0 : "$(AppIdentifierPrefix)\($0)" }),
        LocalCapability(
            slug: "background-modes", name: "Background Modes", key: nil,
            unsupportedReason: "Background Modes are Info.plist keys (UIBackgroundModes), not entitlements; sochi can't edit those yet",
            defaultValue: nil, normalize: { $0 }),
    ]
}

/// Turns a capability into entitlements using Apple's data:
/// - which keys: the catalog's keys for the platform; required ones, or all of them when none is required;
/// - each key's plist type and allowed values: Xcode's schema, then Apple's docs, then the catalog;
/// - values: booleans `true`, push environments `development`, a single allowed constant as-is; keys whose
///   catalog value is an identifier placeholder or wildcard take the user's values (or a derivable default).
public enum CapabilityWriter {
    public static func resolve(_ query: String, catalog: CapabilityCatalog) throws -> ResolvedCapability {
        if let local = LocalCapability.all.first(where: { $0.slug == query.lowercased() || $0.name.lowercased() == query.lowercased() }) {
            return .local(local)
        }
        return .catalog(try catalog.find(query))
    }

    public static func entries(
        for capability: ResolvedCapability, values: [String], bundleID: String,
        schema: EntitlementSchema, platform: String = "IOS"
    ) async throws -> [String: PlistValue] {
        switch capability {
        case .local(let local):
            guard let key = local.key else { throw SochiError.capabilityUnsupported(local.name, local.unsupportedReason ?? "") }
            let list = values.isEmpty ? local.defaultValue.map { [$0(bundleID)] } ?? [] : values.map(local.normalize)
            return [key: .array(list)]
        case .catalog(let entry):
            return try await catalogEntries(entry, values: values, schema: schema, platform: platform)
        }
    }

    static func catalogEntries(
        _ capability: CapabilityCatalog.Capability, values: [String], schema: EntitlementSchema, platform: String
    ) async throws -> [String: PlistValue] {
        var entitlements = capability.entitlements(for: platform)
        if entitlements.isEmpty {
            // Some capabilities are configured by an entitlement Xcode knows by the capability's name (Data Protection).
            guard let key = schema.key(titled: capability.name) else {
                throw SochiError.capabilityHasNoEntitlements(capability.name)
            }
            entitlements = [.init(key: key.name, valueType: .unknown, isRequired: true,
                                  values: key.allowedValues.map { .init(value: $0, inference: "constant") }, platforms: [])]
        }
        let hasRequired = entitlements.contains(where: \.isRequired)
        var remaining = values
        var result: [String: PlistValue] = [:]

        for entitlement in entitlements where entitlement.isRequired || !hasRequired {
            // Xcode's schema first; Apple's docs fill in what it lacks (often the allowed values).
            var info = schema[entitlement.key]
            if info == nil || info!.allowedValues.isEmpty, let documented = await EntitlementSchema.documented(entitlement.key) {
                info = EntitlementSchema.Key(
                    name: entitlement.key, kind: info?.kind ?? documented.kind, title: info?.title ?? documented.title,
                    allowedValues: documented.allowedValues)
            }
            let kind = info?.kind ?? kind(of: entitlement.valueType)
            let constants = entitlement.values.filter { !$0.isPlaceholder && $0.inference != "wildcard" }.map(\.value)
            let allowed = info?.allowedValues.isEmpty == false ? info!.allowedValues : constants

            if entitlement.valueType == .environment {
                result[entitlement.key] = .string("development")
                continue
            }
            if kind == .boolean {
                result[entitlement.key] = .bool(true)
                continue
            }

            let chosen: [String]
            let needsInput = entitlement.values.contains { $0.isPlaceholder || $0.inference == "wildcard" }
            if needsInput {
                if !remaining.isEmpty {
                    chosen = remaining
                    remaining = []
                } else if let derived = entitlement.values.compactMap({ derivedDefault($0.value) }).first {
                    chosen = [derived]
                } else {
                    throw SochiError.capabilityNeedsValue(
                        capability: capability.slug, key: entitlement.key,
                        hint: entitlement.values.first.flatMap { placeholderHint($0.value) },
                        documentation: capability.documentationURL)
                }
            } else if !remaining.isEmpty {
                if !allowed.isEmpty, let bad = remaining.first(where: { !allowed.contains($0) }) {
                    throw SochiError.invalidCapabilityValue(capability.slug, "doesn't accept '\(bad)'. Options: \(allowed.joined(separator: ", "))")
                }
                chosen = remaining
                remaining = []
            } else if allowed.count == 1 {
                chosen = allowed
            } else {
                throw SochiError.capabilityNeedsChoice(capability: capability.slug, key: entitlement.key, options: allowed)
            }

            switch kind {
            case .array: result[entitlement.key] = .array(chosen)
            default:
                guard chosen.count == 1 else {
                    throw SochiError.invalidCapabilityValue(capability.slug, "takes a single value for \(entitlement.key)")
                }
                result[entitlement.key] = .string(chosen[0])
            }
        }
        if !remaining.isEmpty { throw SochiError.invalidCapabilityValue(capability.slug, "takes no values") }
        return result
    }

    /// Keys a capability owns, for detection and removal.
    public static func keys(of capability: ResolvedCapability, schema: EntitlementSchema, platform: String = "IOS") -> [String] {
        switch capability {
        case .local(let local): return local.key.map { [$0] } ?? []
        case .catalog(let entry):
            let keys = entry.entitlements(for: platform).map(\.key)
            return keys.isEmpty ? schema.key(titled: entry.name).map { [$0.name] } ?? [] : keys
        }
    }

    /// Merges entries into entitlements; lists are unioned, preserving existing order.
    public static func adding(_ entries: [String: PlistValue], to entitlements: [String: Any]) -> [String: Any] {
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

    /// Removes a capability's keys, or only the given values from its array keys.
    public static func removing(keys: [String], values: [String], from entitlements: [String: Any]) -> [String: Any] {
        var result = entitlements
        for key in keys {
            if values.isEmpty {
                result[key] = nil
            } else if let list = result[key] as? [String] {
                let remaining = list.filter { value in !values.contains(value) && !values.contains { value.hasSuffix(")\($0)") } }
                result[key] = remaining.isEmpty ? nil : remaining
            }
        }
        return result
    }

    private static func kind(of type: CapabilityCatalog.Entitlement.ValueType) -> EntitlementSchema.Kind {
        switch type {
        case .boolean: .boolean
        case .array: .array
        default: .string
        }
    }

    /// Portal placeholders that map onto Xcode build variables, e.g. `${team.displayId}.*` (iCloud key-value store).
    static func derivedDefault(_ placeholder: String) -> String? {
        placeholder == "${team.displayId}.*" ? "$(TeamIdentifierPrefix)$(CFBundleIdentifier)" : nil
    }

    /// A human hint for an identifier placeholder like `${applicationGroupBundle.specialIdentifier.identifier}`.
    static func placeholderHint(_ placeholder: String) -> String? {
        guard let kind = placeholder.firstMatch(of: #/\$\{([A-Za-z]+)/#).map({ String($0.1) }) else {
            return nil
        }
        let words = kind.replacingOccurrences(of: "Bundle", with: "")
            .replacing(#/([a-z])([A-Z])/#) { "\($0.1) \($0.2)" }.lowercased()
        return "a registered \(words) identifier"
    }
}
