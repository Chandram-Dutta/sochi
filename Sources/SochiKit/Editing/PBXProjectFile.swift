import Foundation

/// Read-only view of a `project.pbxproj`, parsed with Foundation's OpenStep plist reader.
/// sochi never re-serializes this file; edits are surgical (see `PBXEditor`) and verified by re-parsing.
public struct PBXProjectFile {
    public struct Configuration {
        public let id: String
        public let name: String
        public let buildSettings: [String: Any]
    }

    public struct Target {
        public let id: String
        public let name: String
        public let productType: String?
        public let configurations: [Configuration]
        /// Paths of file-system-synchronized folders, relative to the project directory.
        public let synchronizedFolders: [String]

        public var isApplication: Bool { productType == "com.apple.product-type.application" }
    }

    /// The `.xcodeproj` bundle.
    public let projectURL: URL
    public let text: String
    public let targets: [Target]
    /// Paths of top-level groups (relative to the project directory), keyed by group name.
    let topLevelGroups: [String: String]

    public var pbxprojURL: URL { projectURL.appendingPathComponent("project.pbxproj") }
    public var projectDirectory: URL { projectURL.deletingLastPathComponent() }

    public init(projectURL: URL) throws {
        let url = projectURL.appendingPathComponent("project.pbxproj")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw SochiError.unreadableProject(url.path)
        }
        try self.init(projectURL: projectURL, text: text)
    }

    init(projectURL: URL, text: String) throws {
        self.projectURL = projectURL
        self.text = text
        let objects = try Self.objects(in: text, path: projectURL.path)
        guard let root = objects.values.first(where: { $0["isa"] as? String == "PBXProject" }) else {
            throw SochiError.unreadableProject(projectURL.path)
        }

        targets = (root["targets"] as? [String] ?? []).compactMap { id in
            guard let target = objects[id], target["isa"] as? String == "PBXNativeTarget" else { return nil }
            let listID = target["buildConfigurationList"] as? String ?? ""
            let configIDs = objects[listID]?["buildConfigurations"] as? [String] ?? []
            return Target(
                id: id,
                name: target["name"] as? String ?? id,
                productType: target["productType"] as? String,
                configurations: configIDs.compactMap { configID in
                    objects[configID].map {
                        Configuration(id: configID, name: $0["name"] as? String ?? configID,
                                      buildSettings: $0["buildSettings"] as? [String: Any] ?? [:])
                    }
                },
                synchronizedFolders: (target["fileSystemSynchronizedGroups"] as? [String] ?? [])
                    .compactMap { objects[$0]?["path"] as? String })
        }

        let mainGroup = objects[root["mainGroup"] as? String ?? ""]
        var groups: [String: String] = [:]
        for childID in mainGroup?["children"] as? [String] ?? [] {
            guard let child = objects[childID], child["isa"] as? String == "PBXGroup",
                  let path = child["path"] as? String ?? child["name"] as? String else { continue }
            groups[child["name"] as? String ?? path] = path
        }
        topLevelGroups = groups
    }

    /// The folder holding a target's sources, relative to the project directory, if one is obvious.
    public func sourceFolder(of target: Target) -> String? {
        target.synchronizedFolders.first { $0 == target.name }
            ?? target.synchronizedFolders.first
            ?? topLevelGroups[target.name]
    }

    static func objects(in text: String, path: String) throws -> [String: [String: Any]] {
        guard let root = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]]
        else { throw SochiError.unreadableProject(path) }
        return objects
    }
}
