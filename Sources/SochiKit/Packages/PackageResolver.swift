import Foundation

/// Talks to Apple's tools about packages: `xcodebuild -resolvePackageDependencies` picks versions and writes
/// Package.resolved, `swift package dump-package` reports a package's real products, `git ls-remote` finds versions.
public enum PackageResolver {
    public struct Product: Sendable, Equatable {
        public let name: String
        public let isLibrary: Bool
    }

    /// A pinned version from Package.resolved.
    public struct Pin: Sendable, Equatable {
        public let identity: String
        public let version: String?
        public let branch: String?
        public let revision: String?

        public var description: String {
            version ?? branch.map { "\($0) @ \(revision?.prefix(7) ?? "?")" } ?? revision.map { String($0.prefix(7)) } ?? "?"
        }
    }

    /// Resolves the project's packages into sochi's shared checkout folder and updates Package.resolved.
    static func resolve(project: XcodeProject, scheme: String?) async throws {
        var args = ["xcodebuild", "-resolvePackageDependencies"] + project.xcodebuildArguments
        if project.kind == .workspace, let scheme { args += ["-scheme", scheme] }
        args += ["-clonedSourcePackagesDirPath", sourcePackages(for: project).path]
        let collector = ErrorCollector()
        let status = try await Shell.stream(args, cwd: project.directory) { collector.consume($0) }
        guard status == 0 else { throw SochiError.packageResolutionFailed(collector.errors) }
    }

    /// Checkouts live next to sochi's DerivedData for the project, so `sochi run` reuses them.
    static func sourcePackages(for project: XcodeProject) -> URL {
        Paths.projectCache(for: project).appendingPathComponent("DerivedData/SourcePackages")
    }

    /// The library products a resolved (or local) package offers, read from its manifest.
    static func products(of spec: PackageSpec, project: XcodeProject) async throws -> [Product] {
        let directory: URL
        switch spec.source {
        case .local(let path):
            directory = project.directory.appendingPathComponent(path).standardizedFileURL
        case .remote:
            directory = try checkout(of: spec.identity, in: sourcePackages(for: project))
        }
        let json = try await Shell.run(["swift", "package", "dump-package", "--package-path", directory.path])
        guard let manifest = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw SochiError.unexpectedOutput(command: "swift package dump-package")
        }
        return (manifest["products"] as? [[String: Any]] ?? []).compactMap { product in
            guard let name = product["name"] as? String else { return nil }
            let type = product["type"] as? [String: Any] ?? [:]
            return Product(name: name, isLibrary: type["library"] != nil)
        }
    }

    /// Where a resolved package was checked out, from SwiftPM's workspace state.
    static func checkout(of identity: String, in sourcePackages: URL) throws -> URL {
        let state = sourcePackages.appendingPathComponent("workspace-state.json")
        guard let data = try? Data(contentsOf: state),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = (root["object"] as? [String: Any])?["dependencies"] as? [[String: Any]]
        else { throw SochiError.packageNotResolved(identity) }
        for dependency in dependencies {
            let ref = dependency["packageRef"] as? [String: Any] ?? [:]
            guard (ref["identity"] as? String)?.lowercased() == identity, let subpath = dependency["subpath"] as? String else { continue }
            return sourcePackages.appendingPathComponent("checkouts").appendingPathComponent(subpath)
        }
        throw SochiError.packageNotResolved(identity)
    }

    /// The newest release version tagged in a repository (`1.2.3` or `v1.2.3`, no pre-releases).
    static func latestVersion(of url: String) async throws -> String? {
        let output = try await Shell.run(["git", "ls-remote", "--tags", "--refs", url])
        let versions = output.split(separator: "\n").compactMap { line -> (String, [Int])? in
            guard let tag = line.split(separator: "/").last.map(String.init) else { return nil }
            let bare = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let parts = bare.split(separator: ".").map { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
            return (bare, parts.map { $0! })
        }
        return versions.max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    /// Package.resolved for a project (inside the workspace when there is one).
    static func resolvedFile(for project: XcodeProject) -> URL {
        switch project.kind {
        case .workspace: project.url.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        case .project: project.url.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        }
    }

    public static func pins(for project: XcodeProject) -> [String: Pin] {
        guard let data = try? Data(contentsOf: resolvedFile(for: project)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        // Version 2/3 files have top-level "pins"; version 1 nests them under "object".
        let pins = root["pins"] as? [[String: Any]] ?? (root["object"] as? [String: Any])?["pins"] as? [[String: Any]] ?? []
        var result: [String: Pin] = [:]
        for pin in pins {
            let identity = (pin["identity"] as? String ?? pin["package"] as? String ?? "").lowercased()
            let state = pin["state"] as? [String: Any] ?? [:]
            result[identity] = Pin(identity: identity, version: state["version"] as? String,
                                   branch: state["branch"] as? String, revision: state["revision"] as? String)
        }
        return result
    }

    /// Removes pins so the next resolve picks the newest versions the requirements allow.
    static func unpin(_ identities: Set<String>?, in project: XcodeProject) throws {
        let url = resolvedFile(for: project)
        guard let data = try? Data(contentsOf: url), var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = root["pins"] as? [[String: Any]] else { return }
        root["pins"] = pins.filter { pin in
            guard let identities else { return false }
            return !identities.contains((pin["identity"] as? String ?? "").lowercased())
        }
        // The origin hash marks the file as matching the manifests; drop it so SwiftPM re-resolves and rewrites it.
        root["originHash"] = nil
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

/// Collects error lines from a streamed command, including the indented detail lines xcodebuild prints under them
/// (e.g. why package resolution failed). Falls back to the last lines of output when nothing looked like an error.
/// Lines arrive on one background thread.
final class ErrorCollector: @unchecked Sendable {
    private var collected: [String] = []
    private var tail: [String] = []
    private var inError = false

    var errors: [String] { collected.isEmpty ? tail.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : collected }

    func consume(_ line: String) {
        tail.append(line)
        if tail.count > 8 { tail.removeFirst() }
        if case .diagnostic(let d) = BuildLog.parse(line), d.severity == .error {
            inError = true
            if collected.count < 10 { collected.append(d.message) }
        } else if inError, line.hasPrefix("  "), collected.count < 10 {
            collected.append(line.trimmingCharacters(in: .whitespaces))
        } else {
            inError = false
        }
    }
}
