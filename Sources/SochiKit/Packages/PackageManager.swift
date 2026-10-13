import Foundation

/// `sochi add/remove package`, `sochi packages`, `sochi update` and `sochi sync`.
///
/// The Xcode project and Package.resolved stay what Xcode reads; sochi.toml is the readable side. Both are kept in step:
/// commands change both, and `sync` reconciles edits made on either side (sochi.toml by hand, the project in Xcode)
/// against a per-machine snapshot of the last sync, so an addition on one side is never mistaken for a removal on the
/// other. Without a snapshot (e.g. a fresh clone) sync only adds; same-package changes on both sides are conflicts.
public enum PackageManager {
    struct Context {
        let project: XcodeProject
        let file: PBXProjectFile
        var config: SochiConfig?
        let base: [String: PackageSpec]?
        let packages: ProjectPackages

        static func load(path: String, force: Bool) throws -> Context {
            let project = try XcodeProject.locate(path)
            if !force, let marker = ProjectEditor.generatorMarker(in: project.directory) { throw SochiError.generatedProject(marker) }
            let projects = try ProjectEditor.projectFiles(for: project)
            guard projects.count == 1 else { throw SochiError.ambiguousProject(projects) }
            let file = try PBXProjectFile(projectURL: projects[0])
            return Context(project: project, file: file, config: try SochiConfig.load(projectDirectory: project.directory),
                           base: PackageManager.loadBase(project), packages: ProjectPackages(file))
        }
    }

    public struct Outcome: Sendable {
        public var plan: EditPlan
        public var notes: [String] = []
        /// Identity → resolved version after applying (filled by `finish`).
        public var resolved: [String: String] = [:]
        let project: XcodeProject
        let finalSpecs: [String: PackageSpec]
        let validate: [PackageSpec]
    }

    // MARK: add

    public static func planAdd(
        source: String, requirement: PackageSpec.Requirement?, products requested: [String], target targetName: String?,
        path: String, force: Bool
    ) async throws -> Outcome {
        let context = try Context.load(path: path, force: force)
        let (file, project) = (context.file, context.project)
        let target = try ProjectEditor.pickTarget(named: targetName, in: [file], project: project).1

        // Where it comes from: a local folder with a Package.swift, or a repository (owner/repo means GitHub).
        let specSource: PackageSpec.Source
        let localURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        if FileManager.default.fileExists(atPath: localURL.appendingPathComponent("Package.swift").path) {
            specSource = .local(path: relativePath(from: project.directory, to: localURL))
        } else {
            let url = source.wholeMatch(of: #/[\w.-]+\/[\w.-]+/#) != nil && !source.contains(":") ? "https://github.com/\(source)" : source
            if let requirement {
                specSource = .remote(url: url, requirement: requirement)
            } else {
                guard let latest = try await PackageResolver.latestVersion(of: url) else { throw SochiError.packageHasNoVersions(url) }
                specSource = .remote(url: url, requirement: .upToNextMajor(latest))
            }
        }
        let identity: String
        switch specSource {
        case .local(let relative): identity = project.directory.appendingPathComponent(relative).standardizedFileURL.lastPathComponent.lowercased()
        case .remote(let url, _): identity = PackageSpec.identity(of: url)
        }
        let existing = context.packages.specs[identity]
        var declared = PackageSpec(identity: identity, source: specSource, products: existing?.products ?? [:])

        // Which products: validated against the package's own manifest (resolving it first if it's remote).
        let available: [PackageResolver.Product]
        if case .remote = specSource {
            available = try await resolvedProducts(of: declared, context: context)
        } else {
            available = try await PackageResolver.products(of: declared, project: project)
        }
        let libraries = available.filter(\.isLibrary).map(\.name)
        let chosen: [String]
        if requested.isEmpty {
            guard libraries.count == 1 else { throw SochiError.packageNeedsProduct(identity, available: libraries) }
            chosen = libraries
        } else {
            if let unknown = requested.first(where: { !libraries.contains($0) }) {
                throw SochiError.unknownProduct(unknown, package: identity, available: libraries)
            }
            chosen = requested
        }
        declared = declared.adding(products: [target.name: chosen])

        let outcome = try plan(context, set: [declared], remove: [], note: existing == nil
            ? "\(identity) \(declared.requirementDescription) → \(target.name): \(chosen.joined(separator: ", "))"
            : "\(identity) → \(target.name): \(chosen.joined(separator: ", ")) (already declared: \(existing!.requirementDescription))")
        return outcome
    }

    // MARK: remove

    public static func planRemove(identity query: String, target targetName: String?, path: String, force: Bool) throws -> Outcome {
        let context = try Context.load(path: path, force: force)
        let identity = query.lowercased()
        guard var spec = context.packages.specs[identity] else {
            throw SochiError.unknownPackage(query, available: context.packages.specs.keys.sorted())
        }
        if let targetName {
            guard spec.products[targetName] != nil else { throw SochiError.unknownTarget(targetName, available: spec.products.keys.sorted()) }
            spec.products[targetName] = nil
            if !spec.products.isEmpty {
                return try plan(context, set: [spec], remove: [], note: "\(identity): no longer used by \(targetName)")
            }
        }
        return try plan(context, set: [], remove: [identity], note: "removing \(identity)")
    }

    // MARK: sync

    /// Reconciles sochi.toml and the project. With no sochi.toml yet, creates one from the project.
    public static func planSync(path: String, force: Bool) throws -> Outcome {
        let context = try Context.load(path: path, force: force)
        let project = context.packages.specs
        guard let config = context.config else {
            return try plan(context, set: [], remove: [], note: "creating sochi.toml from the project's \(project.count) package\(project.count == 1 ? "" : "s")",
                            forceConfig: true)
        }
        let declared = Dictionary(config.packages.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        let base = context.base
        var toProject: [PackageSpec] = [], removeFromProject: [String] = []
        var toConfig: [PackageSpec] = [], removeFromConfig: [String] = []
        var conflicts: [String] = [], notes: [String] = []

        for identity in Set(project.keys).union(declared.keys).union(base?.keys ?? [String: PackageSpec]().keys).sorted() {
            let (p, t, b) = (project[identity], declared[identity], base?[identity])
            switch (p, t) {
            case let (p?, t?) where p == t:
                continue
            case let (p?, t?):
                if b == p { toProject.append(t); notes.append("\(identity): sochi.toml changed it, updating the project") }
                else if b == t { toConfig.append(p); notes.append("\(identity): changed in the project, updating sochi.toml") }
                else { conflicts.append("\(identity): sochi.toml has \(t.requirementDescription) \(t.products), the project has \(p.requirementDescription) \(p.products)") }
            case let (p?, nil):
                if let b, b == p { removeFromProject.append(identity); notes.append("\(identity): removed from sochi.toml, removing from the project") }
                else if b != nil { conflicts.append("\(identity): removed from sochi.toml but changed in the project") }
                else { toConfig.append(p); notes.append("\(identity): added in the project, adding to sochi.toml") }
            case let (nil, t?):
                if let b, b == t { removeFromConfig.append(identity); notes.append("\(identity): removed from the project, removing from sochi.toml") }
                else if b != nil { conflicts.append("\(identity): removed from the project but changed in sochi.toml") }
                else { toProject.append(t); notes.append("\(identity): added in sochi.toml, adding to the project") }
            case (nil, nil):
                continue
            }
        }
        guard conflicts.isEmpty else { throw SochiError.packageConflict(conflicts) }
        var outcome = try plan(context, set: toProject, remove: removeFromProject, note: nil,
                               configSet: toConfig, configRemove: removeFromConfig)
        outcome.notes = notes + outcome.notes
        return outcome
    }

    // MARK: plan / apply

    /// Builds the edits for the project (and sochi.toml, kept equal to the project's packages afterwards).
    static func plan(
        _ context: Context, set: [PackageSpec], remove: [String], note: String?,
        configSet: [PackageSpec]? = nil, configRemove: [String]? = nil, forceConfig: Bool = false
    ) throws -> Outcome {
        let file = context.file
        var plan = EditPlan(target: context.project.name, projectURL: file.projectURL)
        var finalSpecs = context.packages.specs
        if !set.isEmpty || !remove.isEmpty {
            let text = try ProjectPackages.edit(file, set: set, remove: remove)
            plan.edits.append(.init(url: file.pbxprojURL, original: Data(file.text.utf8), updated: Data(text.utf8)))
            for spec in set { finalSpecs[spec.identity] = spec }
            for identity in remove { finalSpecs[identity] = nil }
        }
        // sochi.toml follows the project (created on first use with everything the project already declares).
        var config = context.config ?? SochiConfig.new(projectDirectory: context.project.directory)
        let original = context.config.map { Data($0.text.utf8) }
        if context.config == nil {
            // A new sochi.toml starts with everything the project declares.
            for spec in finalSpecs.values.sorted(by: { $0.identity < $1.identity }) { try config.set(spec) }
        } else {
            for spec in configSet ?? set { try config.set(spec) }
            for identity in configRemove ?? remove { try config.remove(identity) }
        }
        if Data(config.text.utf8) != original || forceConfig && context.config == nil {
            plan.edits.append(.init(url: config.url, original: original, updated: Data(config.text.utf8)))
        }
        return Outcome(plan: plan, notes: note.map { [$0] } ?? [], project: context.project, finalSpecs: finalSpecs, validate: set)
    }

    /// Writes the plan, resolves packages (updating Package.resolved), checks declared products exist, and records the
    /// sync snapshot. Any failure restores every file.
    public static func finish(_ outcome: Outcome, onStep: @Sendable (String) -> Void) async throws -> Outcome {
        var outcome = outcome
        let originals = outcome.plan.edits.map { ($0.url, $0.original) }
        let resolvedFile = PackageResolver.resolvedFile(for: outcome.project)
        let resolvedBefore = try? Data(contentsOf: resolvedFile)
        try await ProjectEditor.apply(outcome.plan)
        do {
            if outcome.plan.edits.contains(where: { $0.url.lastPathComponent == "project.pbxproj" }) {
                onStep("resolving packages")
                try await PackageResolver.resolve(project: outcome.project, scheme: nil)
                for spec in outcome.validate {
                    let libraries = try await PackageResolver.products(of: spec, project: outcome.project).filter(\.isLibrary).map(\.name)
                    for product in spec.products.values.flatMap({ $0 }) where !libraries.contains(product) {
                        throw SochiError.unknownProduct(product, package: spec.identity, available: libraries)
                    }
                }
            }
        } catch {
            for (url, original) in originals {
                if let original { try? original.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
            }
            if let resolvedBefore { try? resolvedBefore.write(to: resolvedFile, options: .atomic) }
            throw error
        }
        saveBase(outcome.finalSpecs, for: outcome.project)
        let pins = PackageResolver.pins(for: outcome.project)
        outcome.resolved = outcome.finalSpecs.keys.reduce(into: [:]) { result, identity in
            if let pin = pins[identity] { result[identity] = pin.description }
        }
        return outcome
    }

    /// Resolves a package that isn't in the project yet, using a throwaway copy of the project next to the original
    /// (existing pins kept), to read its products before anything is written.
    static func resolvedProducts(of spec: PackageSpec, context: Context) async throws -> [PackageResolver.Product] {
        let text = try ProjectPackages.edit(context.file, set: [PackageSpec(identity: spec.identity, source: spec.source)], remove: [])
        let directory = context.file.projectDirectory
        let temp = directory.appendingPathComponent(".sochi-package-\(UUID().uuidString.prefix(8)).xcodeproj")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: temp.appendingPathComponent("project.pbxproj"))
        let tempProject = XcodeProject(kind: .project, url: temp)
        if let pins = try? Data(contentsOf: PackageResolver.resolvedFile(for: context.project)) {
            let destination = PackageResolver.resolvedFile(for: tempProject)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pins.write(to: destination)
        }
        // Share the real project's checkout folder so the later resolve is instant.
        let args = ["xcodebuild", "-resolvePackageDependencies", "-project", temp.path,
                    "-clonedSourcePackagesDirPath", PackageResolver.sourcePackages(for: context.project).path]
        let collector = ErrorCollector()
        let status = try await Shell.stream(args, cwd: directory) { collector.consume($0) }
        guard status == 0 else { throw SochiError.packageResolutionFailed(collector.errors) }
        return try await PackageResolver.products(of: spec, project: context.project)
    }

    /// Records that sochi.toml and the project agree (e.g. after the user resolved a conflict by hand).
    public static func acknowledge(_ outcome: Outcome) {
        saveBase(outcome.finalSpecs, for: outcome.project)
    }

    // MARK: list / update

    public struct Listing: Sendable {
        public struct Entry: Sendable {
            public let spec: PackageSpec
            public let resolved: String?
            /// nil when there's no sochi.toml; otherwise whether it agrees with the project.
            public let inSync: Bool?
        }
        public let entries: [Entry]
        /// Products from pre-Xcode 15 local packages (target, product), shown but not managed.
        public let legacy: [(target: String, product: String)]
        public let hasConfig: Bool
    }

    public static func list(path: String) throws -> Listing {
        let context = try Context.load(path: path, force: true)
        let pins = PackageResolver.pins(for: context.project)
        let declared = context.config.map { Dictionary($0.packages.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a }) }
        let entries = context.packages.specs.values.sorted { $0.identity < $1.identity }.map { spec in
            Listing.Entry(spec: spec, resolved: pins[spec.identity]?.description, inSync: declared.map { $0[spec.identity] == spec })
        }
        return Listing(entries: entries, legacy: context.packages.legacy.map { ($0.target, $0.product) }, hasConfig: context.config != nil)
    }

    /// Re-resolves to the newest versions the requirements allow. Returns identity → (before, after).
    public static func update(_ identities: [String], path: String, onStep: @Sendable (String) -> Void) async throws -> [String: (String?, String?)] {
        let context = try Context.load(path: path, force: true)
        let wanted = identities.isEmpty ? nil : Set(identities.map { $0.lowercased() })
        if let wanted, let unknown = wanted.first(where: { context.packages.specs[$0] == nil }) {
            throw SochiError.unknownPackage(unknown, available: context.packages.specs.keys.sorted())
        }
        let before = PackageResolver.pins(for: context.project)
        let resolvedFile = PackageResolver.resolvedFile(for: context.project)
        let original = try? Data(contentsOf: resolvedFile)
        try PackageResolver.unpin(wanted, in: context.project)
        // SwiftPM also keeps its current choices in the checkout folder's workspace state and prefers them; set that
        // aside so the resolve really picks the newest allowed versions (downloaded repositories are still reused).
        let state = PackageResolver.sourcePackages(for: context.project).appendingPathComponent("workspace-state.json")
        let stateBackup = try? Data(contentsOf: state)
        try? FileManager.default.removeItem(at: state)
        let after: [String: PackageResolver.Pin]
        do {
            onStep("resolving the newest allowed versions")
            try await PackageResolver.resolve(project: context.project, scheme: nil)
            after = PackageResolver.pins(for: context.project)
            // Every remote package must be pinned again; otherwise put the old lockfile back.
            let remotes = context.packages.specs.values.filter { if case .remote = $0.source { true } else { false } }.map(\.identity)
            if let unpinned = remotes.first(where: { after[$0] == nil }) { throw SochiError.packageNotResolved(unpinned) }
        } catch {
            if let original { try? original.write(to: resolvedFile, options: .atomic) }
            if let stateBackup { try? stateBackup.write(to: state, options: .atomic) }
            throw error
        }
        return Set(before.keys).union(after.keys).filter { wanted?.contains($0) ?? true }.reduce(into: [:]) { result, identity in
            if before[identity] != after[identity] { result[identity] = (before[identity]?.description, after[identity]?.description) }
        }
    }

    // MARK: Snapshot of the last sync (per machine)

    static func baseURL(_ project: XcodeProject) -> URL {
        Paths.projectState(for: project).deletingLastPathComponent().appendingPathComponent("packages-synced.toml")
    }

    static func loadBase(_ project: XcodeProject) -> [String: PackageSpec]? {
        guard let text = try? String(contentsOf: baseURL(project), encoding: .utf8),
              let config = try? SochiConfig(url: baseURL(project), text: text) else { return nil }
        return Dictionary(config.packages.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func saveBase(_ specs: [String: PackageSpec], for project: XcodeProject) {
        var config = SochiConfig.new(projectDirectory: project.directory)
        for spec in specs.values.sorted(by: { $0.identity < $1.identity }) { try? config.set(spec) }
        try? FileManager.default.createDirectory(at: baseURL(project).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(config.text.utf8).write(to: baseURL(project), options: .atomic)
    }

    static func relativePath(from base: URL, to target: URL) -> String {
        let from = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let to = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        let path = (ups + to[common...]).joined(separator: "/")
        return path.isEmpty ? "." : path
    }
}
