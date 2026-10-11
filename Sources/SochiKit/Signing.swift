import Foundation

public struct Team: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isFree: Bool
}

public enum Signing {
    /// Teams from the accounts signed into Xcode › Settings › Accounts.
    public static func teams() async throws -> [Team] {
        let plist = try await Shell.run(["defaults", "export", "com.apple.dt.Xcode", "-"])
        return parseTeams(Data(plist.utf8))
    }

    static func parseTeams(_ plist: Data) -> [Team] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let accounts = root["IDEProvisioningTeamByIdentifier"] as? [String: [[String: Any]]]
        else { return [] }
        var seen = Set<String>()
        return accounts.keys.sorted().flatMap { accounts[$0]! }.compactMap { team in
            guard let id = team["teamID"] as? String, seen.insert(id).inserted else { return nil }
            return Team(
                id: id,
                name: team["teamName"] as? String ?? id,
                isFree: team["isFreeProvisioningTeam"] as? Bool ?? false)
        }
    }

    /// The `DEVELOPMENT_TEAM` to override with, or nil to keep the project's own.
    /// An explicit request wins; otherwise only fill the gap when the project has no team and the choice is unambiguous.
    public static func resolveTeam(requested: String?, projectTeam: String?, available: [Team]) throws -> String? {
        if let requested {
            let match = available.first { $0.id == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame }
            return match?.id ?? requested
        }
        if let projectTeam, !projectTeam.isEmpty { return nil }
        switch available.count {
        case 0: throw SochiError.noSigningTeam
        case 1: return available[0].id
        default: throw SochiError.ambiguousTeam(available)
        }
    }
}
