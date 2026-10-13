import Foundation

/// Gives virtual groups (and groups that don't match their folder) real folders by moving their files, so the
/// migration can convert them. Opt-in (`sochi migrate --move-files`): it moves the user's files.
///
/// Each such group gets the folder it implies, `<parent's folder>/<group name>`, and its files move there. Build
/// settings that point at moved files are updated. A group is left untouched (with the reason) when a move could
/// break something sochi can't fix: a destination already exists, a file is missing, outside the project, or
/// referenced twice, or a moved path appears in an .xcconfig, a scheme, or a build-phase script.
public struct Reorganization: Sendable {
    public struct Move: Sendable, Equatable {
        /// Project-relative paths.
        public let from: String
        public let to: String
    }

    public internal(set) var moves: [Move] = []
    /// Groups that get a (new or corrected) folder.
    public internal(set) var groups: [String] = []
    public internal(set) var skipped: [MigrationReport.Skipped] = []
    /// The project file with groups and references pointing at the new locations.
    public internal(set) var text: String
    public let projectURL: URL
}

public enum Reorganizer {
    public static func plan(path: String, force: Bool) throws -> Reorganization {
        let project = try XcodeProject.locate(path)
        if !force, let marker = ProjectEditor.generatorMarker(in: project.directory) { throw SochiError.generatedProject(marker) }
        let projects = try ProjectEditor.projectFiles(for: project)
        guard projects.count == 1 else { throw SochiError.ambiguousProject(projects) }
        return try plan(try PBXProjectFile(projectURL: projects[0]))
    }

    static func plan(_ file: PBXProjectFile) throws -> Reorganization {
        let objects = file.objects
        let fm = FileManager.default
        let projectDir = file.projectDirectory.standardizedFileURL
        var result = Reorganization(text: file.text, projectURL: file.projectURL)
        let root = objects[file.rootID] ?? [:]
        let productsGroup = root["productRefGroup"] as? String

        func relative(_ url: URL) -> String? {
            let base = projectDir.resolvingSymlinksInPath().path + "/"
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
        }
        func resolve(_ object: [String: Any], parent: URL) -> URL? {
            guard let path = object["path"] as? String else { return nil }
            switch object["sourceTree"] as? String ?? "<group>" {
            case "<group>": return parent.appendingPathComponent(path).standardizedFileURL
            case "SOURCE_ROOT": return projectDir.appendingPathComponent(path).standardizedFileURL
            case "<absolute>": return URL(fileURLWithPath: path).standardizedFileURL
            default: return nil
            }
        }
        func display(_ id: String) -> String { objects[id]?["name"] as? String ?? objects[id]?["path"] as? String ?? id }

        // Where moved paths could be referenced outside build settings, which sochi won't rewrite.
        var externalTexts: [(String, String)] = []
        let walker = fm.enumerator(at: projectDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if ["build", "DerivedData", ".build", "Pods", "node_modules"].contains(url.lastPathComponent) { walker?.skipDescendants(); continue }
            if ["xcconfig", "xcscheme"].contains(url.pathExtension), let text = try? String(contentsOf: url, encoding: .utf8) {
                externalTexts.append((relative(url) ?? url.lastPathComponent, text))
            }
        }
        for (id, object) in objects where object["isa"] as? String == "PBXShellScriptBuildPhase" {
            let parts = [object["shellScript"] as? String ?? ""] + (object["inputPaths"] as? [String] ?? []) + (object["outputPaths"] as? [String] ?? [])
            externalTexts.append(("the \"\(object["name"] as? String ?? id)\" script phase", parts.joined(separator: "\n")))
        }

        var writer = PBXTextWriter(file.text)
        var destinations = Set<String>()
        var sources = Set<String>()
        var settingRewrites: [String: String] = [:]

        /// `actual`: where the group's children currently resolve from; `intended`: the folder the group should be.
        func visit(_ groupID: String, actual: URL, intended: URL) {
            guard groupID != productsGroup, let group = objects[groupID], group["isa"] as? String == "PBXGroup",
                  !Migration.onlyExternalReferences(groupID, objects: objects) else { return }
            var moves: [Reorganization.Move] = []
            var refEdits: [(String, String)] = []  // reference ID → new path relative to the group
            var problem: String?

            func plan(file id: String, current: URL?, destination: URL, newPath: String) {
                guard problem == nil else { return }
                guard let current else { problem = "\(display(id)) isn't stored relative to the project"; return }
                guard let from = relative(current) else { problem = "\(display(id)) lives outside the project folder"; return }
                guard fm.fileExists(atPath: current.path) else { problem = "\(from) is missing on disk"; return }
                guard let to = relative(destination) else { problem = "\(display(id)) would move outside the project"; return }
                refEdits.append((id, newPath))
                guard from != to else { return }
                if fm.fileExists(atPath: destination.path) { problem = "\(to) already exists"; return }
                if sources.contains(from) || destinations.contains(to) { problem = "\(from) is referenced twice"; return }
                if let (place, _) = externalTexts.first(where: { $0.1.contains(from) }) {
                    problem = "\(from) is referenced by path in \(place), which sochi won't rewrite"; return
                }
                moves.append(.init(from: from, to: to))
            }

            for child in group["children"] as? [String] ?? [] {
                guard let object = objects[child] else { continue }
                switch object["isa"] as? String {
                case "PBXFileReference", "XCVersionGroup":
                    guard ["<group>", "SOURCE_ROOT", "<absolute>"].contains(object["sourceTree"] as? String ?? "<group>") else { continue }
                    let current = resolve(object, parent: actual)
                    let name = current?.lastPathComponent ?? display(child)
                    plan(file: child, current: current, destination: intended.appendingPathComponent(name), newPath: name)
                case "PBXVariantGroup":
                    for localized in object["children"] as? [String] ?? [] {
                        guard let ref = objects[localized] else { continue }
                        let current = resolve(ref, parent: actual)
                        let lproj = current?.deletingLastPathComponent().lastPathComponent ?? ""
                        let newPath = lproj.hasSuffix(".lproj") ? "\(lproj)/\(current!.lastPathComponent)" : (current?.lastPathComponent ?? "")
                        plan(file: localized, current: current, destination: intended.appendingPathComponent(newPath), newPath: newPath)
                    }
                default: break
                }
            }

            let currentFolder = resolve(group, parent: actual)
            let mirrors = currentFolder?.standardizedFileURL.path == intended.standardizedFileURL.path
            if let problem {
                result.skipped.append(.init(group: display(groupID), reason: problem))
                return  // leave this group and everything under it as it is
            }
            if !moves.isEmpty || !mirrors {
                if groupID != (root["mainGroup"] as? String) {
                    result.groups.append(display(groupID))
                    let folderName = intended.lastPathComponent
                    writer.setKeys(["path": folderName, "sourceTree": "<group>"], removing: (group["name"] as? String) == folderName ? ["name"] : [], of: groupID)
                }
                for (ref, newPath) in refEdits {
                    let refName = objects[ref]?["name"] as? String
                    writer.setKeys(["path": newPath, "sourceTree": "<group>"], removing: refName == newPath ? ["name"] : [], of: ref)
                }
                for move in moves {
                    sources.insert(move.from)
                    destinations.insert(move.to)
                    settingRewrites[move.from] = move.to
                }
                result.moves += moves
            }
            for child in group["children"] as? [String] ?? [] where objects[child]?["isa"] as? String == "PBXGroup" {
                let childGroup = objects[child]!
                let childActual = resolve(childGroup, parent: actual) ?? actual
                let name = childGroup["name"] as? String ?? (childGroup["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Group"
                guard !name.contains("/") else {
                    result.skipped.append(.init(group: name, reason: "its name can't be a folder name"))
                    continue
                }
                // Keep folders that already match; otherwise the group's folder is its name inside the parent's.
                let mirrorsAlready = (childGroup["path"] as? String).map { intended.appendingPathComponent($0).standardizedFileURL.path == childActual.path } ?? false
                visit(child, actual: childActual, intended: mirrorsAlready ? childActual : intended.appendingPathComponent(name))
            }
        }
        visit(root["mainGroup"] as? String ?? "", actual: projectDir, intended: projectDir)
        guard !result.moves.isEmpty || !result.groups.isEmpty else { return result }

        // Build settings that point at moved files follow them.
        var text = writer.text
        for (configID, config) in objects where config["isa"] as? String == "XCBuildConfiguration" {
            for (key, value) in config["buildSettings"] as? [String: Any] ?? [:] {
                guard let string = value as? String else { continue }
                for prefix in ["", "$(SRCROOT)/", "$(PROJECT_DIR)/", "${SRCROOT}/", "${PROJECT_DIR}/"] {
                    guard string.hasPrefix(prefix), let moved = settingRewrites[String(string.dropFirst(prefix.count))] else { continue }
                    text = try PBXEditor.setBuildSetting(key, to: prefix + moved, configurations: [configID], in: text)
                }
            }
        }
        _ = try PBXProjectFile.objects(in: text, path: file.pbxprojURL.path)
        result.text = text
        return result
    }

    /// Performs the moves, creating folders as needed. Returns an undo closure that restores everything it changed.
    static func perform(_ reorganization: Reorganization) throws -> () -> Void {
        let fm = FileManager.default
        let root = reorganization.projectURL.deletingLastPathComponent()
        var done: [Reorganization.Move] = []
        var createdDirectories: [URL] = []
        let undo = {
            for move in done.reversed() {
                try? fm.moveItem(at: root.appendingPathComponent(move.to), to: root.appendingPathComponent(move.from))
            }
            for dir in createdDirectories.reversed() {
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
            }
        }
        do {
            for move in reorganization.moves {
                let destination = root.appendingPathComponent(move.to)
                var dir = destination.deletingLastPathComponent()
                var missing: [URL] = []
                while !fm.fileExists(atPath: dir.path) { missing.append(dir); dir = dir.deletingLastPathComponent() }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                createdDirectories += missing.reversed()
                try fm.moveItem(at: root.appendingPathComponent(move.from), to: destination)
                done.append(move)
            }
        } catch {
            undo()
            throw error
        }
        return undo
    }
}

extension PBXTextWriter {
    /// Sets (and removes) keys of an object, single-line (`{isa = …; path = …; }`) or multi-line, keeping Xcode's key
    /// order (`isa` first, then alphabetical).
    mutating func setKeys(_ values: [String: String], removing: Set<String> = [], of objectID: String) {
        let q = PBXEditor.quote
        guard let start = lines.firstIndex(where: { Self.objectID($0) == objectID }) else { return }
        let line = lines[start]
        if !line.hasSuffix("= {"), let open = line.range(of: "= {"), let close = line.range(of: "};", options: .backwards) {
            var pairs = Self.splitPairs(String(line[open.upperBound..<close.lowerBound]))
            pairs.removeAll { removing.contains($0.key) || values[$0.key] != nil }
            pairs += values.map { ($0.key, q($0.value)) }
            pairs.sort { ($0.key == "isa" ? "" : $0.key) < ($1.key == "isa" ? "" : $1.key) }
            lines[start] = String(line[..<open.upperBound]) + pairs.map { "\($0.key) = \($0.value); " }.joined() + "};"
            return
        }
        guard let end = lines[start...].firstIndex(of: "\t\t};") else { return }
        var body = Array(lines[(start + 1)..<end])
        let keyOf: (String) -> String? = { line in
            guard line.hasPrefix("\t\t\t"), !line.hasPrefix("\t\t\t\t") else { return nil }
            return line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ").first
        }
        body.removeAll { line in keyOf(line).map { removing.contains($0) || (values[$0] != nil) } ?? false }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let entry = "\t\t\t\(key) = \(q(value));"
            let index = body.firstIndex { line in keyOf(line).map { $0 != "isa" && $0 > key } ?? false } ?? body.count
            body.insert(entry, at: index)
        }
        lines.replaceSubrange((start + 1)..<end, with: body)
    }

    /// Splits `isa = X; path = "a; b"; …` into key/value pairs, respecting quotes.
    static func splitPairs(_ text: String) -> [(key: String, value: String)] {
        var pairs: [(String, String)] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; current.append(character); continue }
            if character == "\"" { quoted.toggle() }
            if character == ";" && !quoted {
                let parts = current.components(separatedBy: " = ")
                if parts.count >= 2 {
                    pairs.append((parts[0].trimmingCharacters(in: .whitespaces), parts.dropFirst().joined(separator: " = ").trimmingCharacters(in: .whitespaces)))
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        return pairs
    }
}

extension Migration {
    /// `sochi migrate --move-files`: reorganize, convert, and (unless `verify` is false) prove the build is unchanged
    /// apart from source paths moving. Any failure restores every file and the original project.
    public static func moveAndConvert(
        _ reorganization: Reorganization, verify: Bool, onStep: @Sendable (String) -> Void
    ) async throws -> (MigrationReport, BuildInventory?) {
        let project = reorganization.projectURL
        let root = project.deletingLastPathComponent()
        let pbxproj = project.appendingPathComponent("project.pbxproj")
        let original = try Data(contentsOf: pbxproj)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var before: BuildInventory?
        if verify {
            onStep("building the project as it is")
            before = try await MigrationVerifier.inventory(project: project, root: root, scratch: scratch.appendingPathComponent("before"))
        }

        onStep("moving \(reorganization.moves.count) files")
        let undoMoves = try Reorganizer.perform(reorganization)
        func rollback() {
            try? original.write(to: pbxproj, options: .atomic)
            undoMoves()
        }
        do {
            try Data(reorganization.text.utf8).write(to: pbxproj, options: .atomic)
            let specs = try await XcodeSpecs.load()
            let (plan, report) = try Migration.plan(try PBXProjectFile(projectURL: project), wrapperExtensions: specs.wrapperExtensions)
            if let edit = plan.edits.first { try edit.updated.write(to: pbxproj, options: .atomic) }
            _ = try PBXProjectFile(projectURL: project)

            guard let before else { return (report, nil) }
            onStep("building the reorganized project")
            let after = try await MigrationVerifier.inventory(project: project, root: root, scratch: scratch.appendingPathComponent("after"))
            // Same build, with compiled sources at their new paths.
            let renames = Dictionary(uniqueKeysWithValues: reorganization.moves.map { ($0.from, $0.to) })
            var expected = before
            expected.sources = before.sources.mapValues { Set($0.map { renames[$0] ?? $0 }) }
            let differences = after.differences(from: expected)
            guard differences.isEmpty else { throw SochiError.migrationChangesBuild(differences) }
            return (report, after)
        } catch {
            rollback()
            throw error
        }
    }
}
