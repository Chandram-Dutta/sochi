import Foundation

/// Apple's own capability catalog, read at runtime from the selected Xcode, never maintained by sochi.
///
/// Sources, best first:
/// 1. `~/Library/Developer/Xcode/UserData/Capabilities/capabilities-<Xcode>-<TEAM>-bundle.json`, the copy Xcode
///    refreshes from Apple for a team (it reflects what that team may use).
/// 2. `DVTPortalCachedPortalCapabilities.json` inside Xcode.app, shipped with Xcode.
///
/// Both are undocumented JSON:API files. Parsing is lenient: unknown fields are ignored, and if neither file can
/// be read sochi reports it and the raw `sochi entitlements` commands remain available.
public struct CapabilityCatalog: Sendable {
    public struct Entitlement: Sendable, Equatable {
        public enum ValueType: String, Sendable {
            case boolean = "BOOLEAN"
            case array = "ARRAY"
            case string = "STRING"
            case environment = "DISTRIBUTION_ENV_SPECIFIC"
            case unknown
        }

        public struct Value: Sendable, Equatable {
            public let value: String
            /// `constant` (literal or `${…}` identifier placeholder) or `wildcard` (any value fits).
            public let inference: String
            public var isPlaceholder: Bool { value.contains("${") }
        }

        public let key: String
        public let valueType: ValueType
        public let isRequired: Bool
        public let values: [Value]
        /// Platforms this key applies to; empty means all of the capability's platforms.
        public let platforms: [String]
    }

    public struct Capability: Sendable {
        /// Portal identifier, e.g. `PUSH_NOTIFICATIONS`.
        public let id: String
        public let name: String
        public let summary: String
        public let documentationURL: String?
        public let platforms: [String]
        public let productTypes: [String]
        public let teamTypes: [String]
        public let isPublic: Bool
        /// Needs Apple's approval before the portal grants it.
        public let needsApproval: Bool
        public let entitlements: [Entitlement]

        /// Command-line name derived from Apple's display name: "Sign In with Apple" → `sign-in-with-apple`.
        public var slug: String {
            name.lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined(separator: "-")
        }

        public func supports(platform: String) -> Bool { platforms.isEmpty || platforms.contains(platform) }

        /// Entitlements that apply on a platform.
        public func entitlements(for platform: String) -> [Entitlement] {
            entitlements.filter { $0.platforms.isEmpty || $0.platforms.contains(platform) }
        }
    }

    public let capabilities: [Capability]
    /// Where the catalog came from, for display.
    public let source: URL

    // MARK: Loading

    /// Loads the best available catalog for the selected Xcode, preferring a team's refreshed copy.
    public static func load(team: String?) async throws -> CapabilityCatalog {
        let developer = try await Shell.run(["xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let xcode = URL(fileURLWithPath: developer).deletingLastPathComponent()
        let version = try? await Xcodebuild.version()
        return try load(xcodeContents: xcode, version: version, team: team)
    }

    static func load(xcodeContents: URL, version: String?, team: String?) throws -> CapabilityCatalog {
        var candidates: [URL] = []
        let userData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Capabilities")
        if let version {
            if let team { candidates.append(userData.appendingPathComponent("capabilities-\(version)-\(team)-bundle.json")) }
            // Any team's refreshed copy for this Xcode is still fresher than the bundled one.
            let others = (try? FileManager.default.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil)) ?? []
            candidates += others.filter { $0.lastPathComponent.hasPrefix("capabilities-\(version)-") }.sorted { $0.path < $1.path }
        }
        candidates.append(xcodeContents.appendingPathComponent(
            "SharedFrameworks/DVTPortal.framework/Versions/A/Resources/DVTPortalCachedPortalCapabilities.json"))
        for url in candidates {
            if let data = try? Data(contentsOf: url), let catalog = try? parse(data, source: url), !catalog.capabilities.isEmpty {
                return catalog
            }
        }
        throw SochiError.xcodeDataUnavailable("the capability catalog")
    }

    static func parse(_ data: Data, source: URL) throws -> CapabilityCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]]
        else { throw SochiError.xcodeDataUnavailable("the capability catalog") }

        func names(_ value: Any?) -> [String] {
            (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String ?? $0["id"] as? String }
        }
        let capabilities = items.compactMap { item -> Capability? in
            guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any],
                  let name = a["name"] as? String else { return nil }
            let entitlements = (a["entitlements"] as? [[String: Any]] ?? []).compactMap { e -> Entitlement? in
                guard let key = e["profileKey"] as? String else { return nil }
                return Entitlement(
                    key: key,
                    valueType: Entitlement.ValueType(rawValue: e["valueType"] as? String ?? "") ?? .unknown,
                    isRequired: e["isRequiredInPlist"] as? Bool ?? false,
                    values: (e["values"] as? [[String: Any]] ?? []).compactMap { v in
                        (v["value"] as? String).map { Entitlement.Value(value: $0, inference: v["inference"] as? String ?? "constant") }
                    },
                    platforms: names(e["supportedSDKs"]))
            }
            return Capability(
                id: id, name: name,
                summary: a["description"] as? String ?? "",
                documentationURL: a["documentationURL"] as? String,
                platforms: names(a["supportedSDKs"]),
                productTypes: a["supportedProductTypes"] as? [String] ?? [],
                teamTypes: a["validTeamTypes"] as? [String] ?? [],
                isPublic: a["isPublic"] as? Bool ?? true,
                needsApproval: (a["distributionApprovalRequired"] as? Bool ?? false) || (a["canRequestFromPortal"] as? Bool ?? false),
                entitlements: entitlements)
        }
        return CapabilityCatalog(capabilities: capabilities, source: source)
    }

    // MARK: Queries

    /// Public capabilities usable on a platform, optionally for a product type.
    public func available(platform: String = "IOS", productType: String? = nil) -> [Capability] {
        capabilities
            .filter { $0.isPublic && $0.supports(platform: platform) }
            .filter { productType == nil || $0.productTypes.isEmpty || $0.productTypes.contains(productType!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Finds a capability by slug, portal ID, or display name, then by unambiguous partial slug.
    public func find(_ query: String, platform: String = "IOS") throws -> Capability {
        let pool = available(platform: platform)
        let q = query.lowercased()
        if let exact = pool.first(where: { $0.slug == q || $0.id.lowercased() == q || $0.name.lowercased() == q }) {
            return exact
        }
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let partial = pool.filter { cap in words.allSatisfy { cap.slug.split(separator: "-").contains(Substring($0)) || cap.slug.contains($0) } }
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty { throw SochiError.unknownCapability(query, available: []) }
        throw SochiError.ambiguousCapability(query, candidates: partial.map(\.slug))
    }

    /// Which capabilities an entitlements dictionary enables (by any of their keys), plus keys no capability claims.
    public func detect(in entitlements: [String: Any], platform: String = "IOS") -> (enabled: [Capability], unclaimed: [String]) {
        let pool = capabilities.filter { $0.supports(platform: platform) }
        var claimed = Set<String>()
        var enabled: [Capability] = []
        for capability in pool {
            let keys = capability.entitlements(for: platform).map(\.key)
            if keys.contains(where: { entitlements[$0] != nil }) {
                // Prefer public entries when several capabilities share a key (e.g. dev/dist variants).
                if !enabled.contains(where: { Set($0.entitlements(for: platform).map(\.key)) == Set(keys) }) {
                    enabled.append(capability)
                }
                claimed.formUnion(keys)
            }
        }
        enabled.sort { $0.name < $1.name }
        return (enabled, entitlements.keys.filter { !claimed.contains($0) }.sorted())
    }
}
