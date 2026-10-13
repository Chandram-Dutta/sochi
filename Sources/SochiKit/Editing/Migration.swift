import Foundation

/// What a migration did, and what it left alone (and why).
public struct MigrationReport: Sendable {
    public struct Converted: Sendable {
        /// Folder path relative to the project directory.
        public let folder: String
        public let targets: [String]
        /// Target → files in the folder that stay out of it.
        public internal(set) var exceptions: [String: [String]]
        /// Target → per-file compiler flags carried over.
        public internal(set) var flags: [String: [String: String]]
    }

    public struct Skipped: Sendable {
        public let group: String
        public let reason: String
    }

    public var converted: [Converted] = []
    public var skipped: [Skipped] = []
    public var targets: [String] = []
}

/// Converts group-based projects to file-system-synchronized folders (Xcode 16's format), so the rest of sochi only
/// ever deals with folders.
///
/// A synchronized folder puts every file inside it into its targets, so a group is converted only when the result
/// is provably the same project:
/// - the group tree mirrors a real folder, and every referenced file exists where the group says;
/// - files on disk that a target didn't use become that target's membership exceptions;
/// - per-file compiler flags carry over; anything else the folder format can't express (other per-file
///   attributes, header visibility, copy-files phases, folder references) leaves the group as it is, with a reason.
public enum Migration {
    struct Subtree {
        let rootID: String
        let directory: URL
        /// Group, file reference, variant group and version group IDs to remove.
        var objectIDs: Set<String> = []
        /// Relative path → reference ID (a variant group's localized files map to the variant group).
        var files: [String: String] = [:]
    }

    struct Membership {
        let target: String
        let targetID: String
        let phaseISA: String
        let buildFileID: String
        let settings: [String: Any]
    }

    public static func plan(path: String, force: Bool) async throws -> (EditPlan, MigrationReport) {
        let project = try XcodeProject.locate(path)
        if !force, let marker = ProjectEditor.generatorMarker(in: project.directory) { throw SochiError.generatedProject(marker) }
        let projects = try ProjectEditor.projectFiles(for: project)
        guard projects.count == 1 else { throw SochiError.ambiguousProject(projects) }
        let file = try PBXProjectFile(projectURL: projects[0])
        let specs = try await XcodeSpecs.load()
        return try plan(file, wrapperExtensions: specs.wrapperExtensions)
    }

    static func plan(_ file: PBXProjectFile, wrapperExtensions: Set<String>) throws -> (EditPlan, MigrationReport) {
        let objects = file.objects
        var report = MigrationReport(targets: file.targets.map(\.name))
        var plan = EditPlan(target: file.projectURL.deletingPathExtension().lastPathComponent, projectURL: file.projectURL)
        plan.expectedTargets = file.targets.map(\.name)

        // Which targets use each reference, through which build phase and with which per-file settings.
        var membership: [String: [Membership]] = [:]
        for target in file.targets {
            for phaseID in objects[target.id]?["buildPhases"] as? [String] ?? [] {
                let phase = objects[phaseID] ?? [:]
                for buildFileID in phase["files"] as? [String] ?? [] {
                    guard let ref = objects[buildFileID]?["fileRef"] as? String else { continue }
                    membership[ref, default: []].append(Membership(
                        target: target.name, targetID: target.id, phaseISA: phase["isa"] as? String ?? "",
                        buildFileID: buildFileID, settings: objects[buildFileID]?["settings"] as? [String: Any] ?? [:]))
                }
            }
        }

        let root = objects[file.rootID] ?? [:]
        let mainGroup = root["mainGroup"] as? String ?? ""
        let productsGroup = root["productRefGroup"] as? String
        var subtrees: [(subtree: Subtree, parentID: String)] = []

        func describe(_ id: String) -> String {
            objects[id]?["name"] as? String ?? objects[id]?["path"] as? String ?? id
        }

        /// Tries to convert a group; if it can't be, records why and tries its child groups instead.
        func consider(_ groupID: String, parentID: String, parentDirectory: URL) {
            guard groupID != productsGroup, let group = objects[groupID], group["isa"] as? String == "PBXGroup" else { return }
            let directory = folder(of: group, parent: parentDirectory, project: file.projectDirectory)
            switch analyze(groupID, directory: directory, project: file.projectDirectory, objects: objects, membership: membership) {
            case .success(let subtree):
                subtrees.append((subtree, parentID))
            case .failure(let reason):
                // Groups of SDK/built products (e.g. "Frameworks") are expected to stay groups; don't report them.
                if !onlyExternalReferences(groupID, objects: objects) {
                    report.skipped.append(.init(group: describe(groupID), reason: reason.text))
                }
                for child in group["children"] as? [String] ?? [] {
                    consider(child, parentID: groupID, parentDirectory: directory ?? parentDirectory)
                }
            }
        }
        for child in objects[mainGroup]?["children"] as? [String] ?? [] {
            consider(child, parentID: mainGroup, parentDirectory: file.projectDirectory)
        }
        guard !subtrees.isEmpty else { return (plan, report) }

        var writer = PBXTextWriter(file.text)
        var used = Set<String>()
        func id() -> String {
            while true {
                let candidate = PBXTextWriter.makeID(avoiding: file.text)
                if used.insert(candidate).inserted { return candidate }
            }
        }
        let q = PBXEditor.quote
        var removed = Set<String>()

        for (subtree, parentID) in subtrees {
            let group = objects[subtree.rootID]!
            let name = group["name"] as? String ?? group["path"] as? String ?? "Folder"
            let onDisk = files(in: subtree.directory, wrapperExtensions: wrapperExtensions,
                               referencedPackages: Set(subtree.files.keys))

            // Per target: what it used, so everything else in the folder becomes an exception.
            var members: [String: (id: String, files: Set<String>, flags: [String: String])] = [:]
            for (relative, ref) in subtree.files {
                for use in membership[ref] ?? [] {
                    var entry = members[use.target] ?? (use.targetID, [], [:])
                    entry.files.insert(relative)
                    if let flags = use.settings["COMPILER_FLAGS"] as? String, !flags.isEmpty { entry.flags[relative] = flags }
                    members[use.target] = entry
                }
                removed.formUnion((membership[ref] ?? []).map(\.buildFileID))
            }

            let syncedID = id()
            var exceptionLines: [String] = []
            var converted = MigrationReport.Converted(
                folder: subtree.directory.resolvingSymlinksInPath().path
                    .replacingOccurrences(of: file.projectDirectory.resolvingSymlinksInPath().path + "/", with: ""),
                targets: members.keys.sorted(), exceptions: [:], flags: [:])
            for targetName in members.keys.sorted() {
                let member = members[targetName]!
                let exceptions = onDisk.subtracting(member.files).sorted()
                converted.exceptions[targetName] = exceptions
                converted.flags[targetName] = member.flags
                try writer.append("\(syncedID) /* \(name) */", to: "fileSystemSynchronizedGroups", ofObject: member.id)
                guard !exceptions.isEmpty || !member.flags.isEmpty else { continue }
                let exceptionID = id()
                let comment = "Exceptions for \"\(name)\" folder in \"\(targetName)\" target"
                var lines = ["\t\t\(exceptionID) /* \(comment) */ = {", "\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;"]
                if !member.flags.isEmpty {
                    lines.append("\t\t\tadditionalCompilerFlagsByRelativePath = {")
                    lines += member.flags.keys.sorted().map { "\t\t\t\t\(q($0)) = \(q(member.flags[$0]!));" }
                    lines.append("\t\t\t};")
                }
                if !exceptions.isEmpty {
                    lines.append("\t\t\tmembershipExceptions = (")
                    lines += exceptions.map { "\t\t\t\t\(q($0))," }
                    lines.append("\t\t\t);")
                }
                lines += ["\t\t\ttarget = \(member.id) /* \(targetName) */;", "\t\t};"]
                writer.insert(object: lines, id: exceptionID, isa: "PBXFileSystemSynchronizedBuildFileExceptionSet")
                exceptionLines.append("\t\t\t\t\(exceptionID) /* \(comment) */,")
            }

            var lines = ["\t\t\(syncedID) /* \(name) */ = {", "\t\t\tisa = PBXFileSystemSynchronizedRootGroup;"]
            if !exceptionLines.isEmpty { lines += ["\t\t\texceptions = ("] + exceptionLines + ["\t\t\t);"] }
            if let groupName = group["name"] as? String, groupName != group["path"] as? String { lines.append("\t\t\tname = \(q(groupName));") }
            if let path = group["path"] as? String { lines.append("\t\t\tpath = \(q(path));") }
            lines += ["\t\t\tsourceTree = \(q(group["sourceTree"] as? String ?? "<group>"));", "\t\t};"]
            writer.insert(object: lines, id: syncedID, isa: "PBXFileSystemSynchronizedRootGroup")
            writer.replaceReference(subtree.rootID, with: syncedID, comment: name, inObject: parentID)
            // Build configurations based on an .xcconfig inside the folder now anchor to the folder (Xcode 16 keys).
            let pathsByRef = Dictionary(subtree.files.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            for (configID, config) in objects where config["isa"] as? String == "XCBuildConfiguration" {
                guard let ref = config["baseConfigurationReference"] as? String, let relative = pathsByRef[ref] else { continue }
                writer.replaceBaseConfiguration(in: configID, anchor: syncedID, anchorName: name, relativePath: relative)
            }
            removed.formUnion(subtree.objectIDs)
            report.converted.append(converted)
        }

        writer.removeObjects(removed)
        writer.setObjectVersion(77)
        let text = writer.text

        // Nothing removed may still be referenced anywhere, and the result must parse.
        for removedID in removed where text.contains(removedID) {
            throw SochiError.editVerificationFailed("\(removedID) is still referenced after migrating")
        }
        _ = try PBXProjectFile.objects(in: text, path: file.pbxprojURL.path)

        plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(text.utf8)))
        return (plan, report)
    }

    // MARK: Analysis

    struct Reason: Error { let text: String }

    static func folder(of group: [String: Any], parent: URL, project: URL) -> URL? {
        let path = group["path"] as? String
        switch group["sourceTree"] as? String ?? "<group>" {
        case "<group>": return path.map { parent.appendingPathComponent($0).standardizedFileURL } ?? nil
        case "SOURCE_ROOT": return path.map { project.appendingPathComponent($0).standardizedFileURL } ?? nil
        default: return nil
        }
    }

    /// Decides whether a group can become a synchronized folder, collecting what it would replace.
    /// True when every file under a group lives outside the project tree (SDK frameworks, build products).
    static func onlyExternalReferences(_ groupID: String, objects: [String: [String: Any]]) -> Bool {
        let children = objects[groupID]?["children"] as? [String] ?? []
        return !children.isEmpty && children.allSatisfy { child in
            guard let object = objects[child] else { return false }
            if object["isa"] as? String == "PBXGroup" { return onlyExternalReferences(child, objects: objects) }
            return !["<group>", "SOURCE_ROOT"].contains(object["sourceTree"] as? String ?? "<group>")
        }
    }

    static func analyze(_ groupID: String, directory: URL?, project: URL, objects: [String: [String: Any]],
                        membership: [String: [Membership]]) -> Result<Subtree, Reason> {
        guard let directory else { return .failure(Reason(text: "it isn't backed by a folder (a virtual group)")) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(Reason(text: "its folder \(directory.lastPathComponent) doesn't exist"))
        }
        var subtree = Subtree(rootID: groupID, directory: directory)

        func relative(_ url: URL) -> String? {
            let base = directory.path + "/"
            let path = url.standardizedFileURL.path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
        }

        func check(_ ref: String, path: String) -> Reason? {
            for use in membership[ref] ?? [] {
                guard ["PBXSourcesBuildPhase", "PBXResourcesBuildPhase"].contains(use.phaseISA) else {
                    return Reason(text: "\(path) is in a \(use.phaseISA.replacingOccurrences(of: "PBX", with: "")) phase of \(use.target), which a folder can't express")
                }
                if let other = use.settings.keys.first(where: { $0 != "COMPILER_FLAGS" }) {
                    return Reason(text: "\(path) has a per-file \(other) setting in \(use.target)")
                }
            }
            return nil
        }

        func walk(_ id: String, in folder: URL) -> Reason? {
            guard let object = objects[id] else { return Reason(text: "it references a missing object") }
            switch object["isa"] as? String {
            case "PBXGroup":
                let childFolder = id == groupID ? directory : Migration.folder(of: object, parent: folder, project: project)
                guard let childFolder, relative(childFolder) != nil || childFolder == directory
                else { return Reason(text: "subgroup \(object["name"] as? String ?? object["path"] as? String ?? "?") doesn't mirror a folder inside it") }
                subtree.objectIDs.insert(id)
                for child in object["children"] as? [String] ?? [] {
                    if let reason = walk(child, in: childFolder) { return reason }
                }
            case "PBXVariantGroup":
                subtree.objectIDs.insert(id)
                if let reason = check(id, path: object["name"] as? String ?? "?") { return reason }
                for child in object["children"] as? [String] ?? [] {
                    guard let ref = objects[child], let url = Migration.folder(of: ref, parent: folder, project: project),
                          FileManager.default.fileExists(atPath: url.path), let path = relative(url)
                    else { return Reason(text: "a localized file of \(object["name"] as? String ?? "?") is missing or outside the folder") }
                    subtree.objectIDs.insert(child)
                    subtree.files[path] = id
                }
            case "PBXFileReference", "XCVersionGroup":
                guard let url = Migration.folder(of: object, parent: folder, project: project) else {
                    return Reason(text: "\(object["name"] as? String ?? object["path"] as? String ?? "?") isn't stored relative to the folder")
                }
                guard let path = relative(url) else { return Reason(text: "\(url.lastPathComponent) lives outside the folder") }
                guard FileManager.default.fileExists(atPath: url.path) else { return Reason(text: "\(path) is missing on disk") }
                if object["lastKnownFileType"] as? String == "folder" {
                    return Reason(text: "\(path) is a folder reference, which sochi doesn't convert yet")
                }
                if subtree.files[path] != nil { return Reason(text: "\(path) is referenced twice") }
                if let reason = check(id, path: path) { return reason }
                subtree.objectIDs.insert(id)
                subtree.objectIDs.formUnion(object["children"] as? [String] ?? [])
                subtree.files[path] = id
            case let other:
                return Reason(text: "it contains a \(other ?? "unknown") item")
            }
            return nil
        }

        if let reason = walk(groupID, in: directory) { return .failure(reason) }
        return .success(subtree)
    }

    /// Files a synchronized folder would see: everything inside it except hidden files; bundles such as asset catalogs
    /// (any extension Xcode's specs mark as a wrapper, or anything the project referenced as one file) are single files.
    static func files(in directory: URL, wrapperExtensions: Set<String>, referencedPackages: Set<String>) -> Set<String> {
        var result = Set<String>()
        func visit(_ url: URL, _ relative: String) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                let path = relative.isEmpty ? entry.lastPathComponent : "\(relative)/\(entry.lastPathComponent)"
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory, !wrapperExtensions.contains(entry.pathExtension.lowercased()), !referencedPackages.contains(path) {
                    visit(entry, path)
                } else {
                    result.insert(path)
                }
            }
        }
        visit(directory, "")
        return result
    }
}

extension PBXTextWriter {
    /// Removes objects (single- or multi-line) and every list entry that refers to them; drops emptied sections.
    mutating func removeObjects(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let id = Self.objectID(line), ids.contains(id) {
                // Multi-line objects open with "= {" and close with a "};" line at object depth.
                if line.hasSuffix("= {") {
                    while index < lines.count, lines[index] != "\t\t};" { index += 1 }
                }
                index += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\t\t\t\t"), trimmed.hasSuffix(","),
               let first = trimmed.split(separator: " ").first.map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }),
               ids.contains(first) {
                index += 1
                continue
            }
            result.append(line)
            index += 1
        }
        // Drop sections left empty, with the blank line that followed them.
        var cleaned: [String] = []
        index = 0
        while index < result.count {
            if result[index].hasPrefix("/* Begin "), index + 1 < result.count, result[index + 1].hasPrefix("/* End ") {
                index += 2
                if index < result.count, result[index].isEmpty { index += 1 }
                continue
            }
            cleaned.append(result[index])
            index += 1
        }
        lines = cleaned
    }

    /// Replaces one list entry inside an object, e.g. a group's child.
    mutating func replaceReference(_ old: String, with new: String, comment: String, inObject objectID: String) {
        guard let start = lines.firstIndex(where: { Self.objectID($0) == objectID }),
              let end = lines[start...].firstIndex(of: "\t\t};") else { return }
        for index in start..<end where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("\(old) ")
            || lines[index].trimmingCharacters(in: .whitespaces) == "\(old)," {
            let indent = String(lines[index].prefix { $0 == "\t" })
            lines[index] = "\(indent)\(new) /* \(comment) */,"
        }
    }

    /// Re-points a configuration's base .xcconfig from a file reference to a path inside a synchronized folder.
    mutating func replaceBaseConfiguration(in configID: String, anchor: String, anchorName: String, relativePath: String) {
        guard let start = lines.firstIndex(where: { Self.objectID($0) == configID }),
              let end = lines[start...].firstIndex(of: "\t\t};"),
              let index = lines[start..<end].firstIndex(where: { $0.hasPrefix("\t\t\tbaseConfigurationReference = ") })
        else { return }
        lines.replaceSubrange(index...index, with: [
            "\t\t\tbaseConfigurationReferenceAnchor = \(anchor) /* \(anchorName) */;",
            "\t\t\tbaseConfigurationReferenceRelativePath = \(PBXEditor.quote(relativePath));",
        ])
    }

    mutating func setObjectVersion(_ version: Int) {
        if let index = lines.firstIndex(where: { $0.hasPrefix("\tobjectVersion = ") }) {
            lines[index] = "\tobjectVersion = \(version);"
        }
    }
}
