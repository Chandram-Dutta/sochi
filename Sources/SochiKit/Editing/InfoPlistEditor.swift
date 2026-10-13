import Foundation

extension ProjectEditor {
    /// Plans an arbitrary change to a target's Info.plist, like Xcode does when a capability needs Info.plist keys.
    /// A target with only a generated Info.plist gets a real one in its source folder: `INFOPLIST_FILE` points at it
    /// (Xcode merges it with the generated keys) and, in a synchronized folder, it's excluded from the target's
    /// resources so the build doesn't copy it twice.
    public static func planInfoPlist(
        path: String, target targetName: String?, force: Bool, label: String, removing: Bool = false,
        mutate: ([String: Any]) throws -> [String: Any]
    ) async throws -> EditPlan {
        let resolved = try await resolveTarget(path: path, name: targetName, force: force)
        let file = resolved.file
        let target = resolved.target
        var plan = EditPlan(target: target.name, projectURL: file.projectURL)
        let configs = target.configurations.map(\.name)
        let plistByConfig = configs.reduce(into: [String: String]()) { result, name in
            if let value = resolved.settings[name]?["INFOPLIST_FILE"], !value.isEmpty { result[name] = value }
        }

        var files: [URL]
        if plistByConfig.isEmpty {
            if removing {
                plan.notes.append("\(target.name) has no Info.plist file, so there's nothing to remove")
                return plan
            }
            let folder = file.sourceFolder(of: target)
            let relative = [folder, "Info.plist"].compactMap { $0 }.joined(separator: "/")
            var text = try PBXEditor.setBuildSetting(
                "INFOPLIST_FILE", to: relative, configurations: target.configurations.map(\.id), in: file.text)
            if let folder, let group = synchronizedGroup(of: target, path: folder, in: file) {
                var writer = PBXTextWriter(text)
                try writer.addMembershipException("Info.plist", group: group, target: target, objects: file.objects)
                text = writer.text
                _ = try PBXProjectFile.objects(in: text, path: file.pbxprojURL.path)
                plan.notes.append("creating \(relative), excluded from \(target.name)'s resources, and setting INFOPLIST_FILE")
            } else {
                plan.notes.append("creating \(relative) and setting INFOPLIST_FILE for \(configs.joined(separator: ", "))")
            }
            plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(text.utf8)))
            configs.forEach { plan.expectedSettings[$0, default: [:]]["INFOPLIST_FILE"] = relative }
            files = [file.projectDirectory.appendingPathComponent(relative)]
        } else if plistByConfig.count < configs.count {
            throw SochiError.mixedInfoPlist(target: target.name, missing: configs.filter { plistByConfig[$0] == nil })
        } else {
            files = Set(plistByConfig.values).sorted().map { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path) : file.projectDirectory.appendingPathComponent(path)
            }
        }

        for url in files {
            let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let current = try original.map { try Entitlements.parse($0, path: url.path) } ?? [:]
            let updated = try mutate(current)
            if original != nil, NSDictionary(dictionary: updated).isEqual(to: current) {
                plan.notes.append("\(url.lastPathComponent): \(label) already \(removing ? "absent" : "up to date")")
                continue
            }
            plan.edits.append(.init(url: url, original: original, updated: try Entitlements.serialize(updated)))
        }
        return plan
    }

    /// The synchronized folder of a target at a project-relative path, if any.
    static func synchronizedGroup(of target: PBXProjectFile.Target, path: String, in file: PBXProjectFile) -> String? {
        (file.objects[target.id]?["fileSystemSynchronizedGroups"] as? [String] ?? []).first { file.objects[$0]?["path"] as? String == path }
    }
}

extension PBXTextWriter {
    /// Excludes a file from a target's membership in a synchronized folder, reusing the target's exception set if present.
    mutating func addMembershipException(
        _ relativePath: String, group: String, target: PBXProjectFile.Target, objects: [String: [String: Any]]
    ) throws {
        let q = PBXEditor.quote
        let existing = (objects[group]?["exceptions"] as? [String] ?? []).first { id in
            objects[id]?["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet"
                && objects[id]?["target"] as? String == target.id
        }
        if let existing {
            if (objects[existing]?["membershipExceptions"] as? [String] ?? []).contains(relativePath) { return }
            try append(q(relativePath), to: "membershipExceptions", ofObject: existing)
            return
        }
        let id = Self.makeID(avoiding: text)
        let name = objects[group]?["path"] as? String ?? "folder"
        let comment = "Exceptions for \"\(name)\" folder in \"\(target.name)\" target"
        insert(object: [
            "\t\t\(id) /* \(comment) */ = {",
            "\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;",
            "\t\t\tmembershipExceptions = (",
            "\t\t\t\t\(q(relativePath)),",
            "\t\t\t);",
            "\t\t\ttarget = \(target.id) /* \(target.name) */;",
            "\t\t};",
        ], id: id, isa: "PBXFileSystemSynchronizedBuildFileExceptionSet")
        try append("\(id) /* \(comment) */", to: "exceptions", ofObject: group)
    }
}
