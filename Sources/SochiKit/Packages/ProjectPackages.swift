import Foundation

/// The Swift packages an Xcode project declares, read from its pbxproj, and edits to them in Xcode's own format
/// (XCRemoteSwiftPackageReference / XCLocalSwiftPackageReference / XCSwiftPackageProductDependency, product build
/// files in the Frameworks phase, and the project's and targets' package lists).
struct ProjectPackages {
    struct ProductDependency {
        let id: String
        let targetID: String
        let target: String
        let product: String
        let packageRef: String?
    }

    var specs: [String: PackageSpec] = [:]
    /// Identity → package reference object ID.
    var refs: [String: String] = [:]
    var dependencies: [ProductDependency] = []

    /// Products of local packages added the pre-Xcode 15 way (a folder in the project, no package reference).
    /// sochi lists these but leaves them to Xcode.
    var legacy: [ProductDependency] { dependencies.filter { $0.packageRef == nil } }

    init(_ file: PBXProjectFile) {
        let objects = file.objects
        for id in objects[file.rootID]?["packageReferences"] as? [String] ?? [] {
            guard let ref = objects[id] else { continue }
            switch ref["isa"] as? String {
            case "XCRemoteSwiftPackageReference":
                guard let url = ref["repositoryURL"] as? String,
                      let requirement = Self.requirement(ref["requirement"] as? [String: Any] ?? [:]) else { continue }
                let identity = PackageSpec.identity(of: url)
                specs[identity] = PackageSpec(identity: identity, source: .remote(url: url, requirement: requirement))
                refs[identity] = id
            case "XCLocalSwiftPackageReference":
                guard let path = ref["relativePath"] as? String else { continue }
                let resolved = file.projectDirectory.appendingPathComponent(path).standardizedFileURL.lastPathComponent
                let identity = resolved.lowercased()
                specs[identity] = PackageSpec(identity: identity, source: .local(path: path))
                refs[identity] = id
            default: continue
            }
        }
        let identityByRef = Dictionary(refs.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for target in file.targets {
            for id in objects[target.id]?["packageProductDependencies"] as? [String] ?? [] {
                guard let dependency = objects[id], let product = dependency["productName"] as? String else { continue }
                let ref = dependency["package"] as? String
                dependencies.append(.init(id: id, targetID: target.id, target: target.name, product: product, packageRef: ref))
                if let ref, let identity = identityByRef[ref], let spec = specs[identity] {
                    specs[identity] = spec.adding(products: [target.name: [product]])
                }
            }
        }
    }

    static func requirement(_ dict: [String: Any]) -> PackageSpec.Requirement? {
        let s = { (key: String) in dict[key] as? String }
        switch s("kind") {
        case "upToNextMajorVersion": return s("minimumVersion").map(PackageSpec.Requirement.upToNextMajor)
        case "upToNextMinorVersion": return s("minimumVersion").map(PackageSpec.Requirement.upToNextMinor)
        case "exactVersion": return s("version").map(PackageSpec.Requirement.exact)
        case "versionRange": return s("minimumVersion").flatMap { min in s("maximumVersion").map { .range(min, $0) } }
        case "branch": return s("branch").map(PackageSpec.Requirement.branch)
        case "revision": return s("revision").map(PackageSpec.Requirement.revision)
        default: return nil
        }
    }

    // MARK: Editing

    /// Makes the project declare exactly `set` for those packages (adding, changing or removing their products per
    /// target) and drops `remove` entirely. Packages not mentioned are left alone. Verified by re-reading.
    static func edit(_ file: PBXProjectFile, set: [PackageSpec], remove: [String]) throws -> String {
        let current = ProjectPackages(file)
        var writer = PBXTextWriter(file.text)
        var used = Set<String>()
        func id() -> String {
            while true {
                let candidate = PBXTextWriter.makeID(avoiding: file.text)
                if used.insert(candidate).inserted { return candidate }
            }
        }
        let q = PBXEditor.quote
        var doomed = Set<String>()

        func dropDependencies(_ dependencies: [ProductDependency]) {
            for dependency in dependencies {
                doomed.insert(dependency.id)
                for (buildFile, object) in file.objects where object["productRef"] as? String == dependency.id { doomed.insert(buildFile) }
            }
        }

        for identity in remove {
            guard let ref = current.refs[identity] else { continue }
            doomed.insert(ref)
            dropDependencies(current.dependencies.filter { $0.packageRef == ref })
        }

        for spec in set {
            let refComment = Self.refComment(spec)
            let refID: String
            if let existing = current.refs[spec.identity] {
                refID = existing
                if current.specs[spec.identity]?.source != spec.source {
                    writer.replaceObject(existing, with: Self.refLines(spec, id: existing))
                }
            } else {
                refID = id()
                writer.insert(object: Self.refLines(spec, id: refID), id: refID, isa: Self.refISA(spec))
                try writer.append("\(refID) /* \(refComment) */", to: "packageReferences", ofObject: file.rootID)
            }
            // Products per target: drop what's no longer wanted, add what's missing.
            let existing = current.dependencies.filter { $0.packageRef == refID }
            dropDependencies(existing.filter { !(spec.products[$0.target] ?? []).contains($0.product) })
            for (targetName, products) in spec.products {
                guard let target = file.targets.first(where: { $0.name == targetName }) else {
                    throw SochiError.unknownTarget(targetName, available: file.targets.map(\.name))
                }
                for product in products where !existing.contains(where: { $0.target == targetName && $0.product == product }) {
                    let dependency = id(), buildFile = id()
                    writer.insert(object: [
                        "\t\t\(dependency) /* \(product) */ = {",
                        "\t\t\tisa = XCSwiftPackageProductDependency;",
                        "\t\t\tpackage = \(refID) /* \(refComment) */;",
                        "\t\t\tproductName = \(q(product));",
                        "\t\t};",
                    ], id: dependency, isa: "XCSwiftPackageProductDependency")
                    writer.insert(object: [
                        "\t\t\(buildFile) /* \(product) in Frameworks */ = {isa = PBXBuildFile; productRef = \(dependency) /* \(product) */; };",
                    ], id: buildFile, isa: "PBXBuildFile")
                    try writer.append("\(dependency) /* \(product) */", to: "packageProductDependencies", ofObject: target.id)
                    let phases = file.objects[target.id]?["buildPhases"] as? [String] ?? []
                    if let frameworks = phases.first(where: { file.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }) {
                        try writer.append("\(buildFile) /* \(product) in Frameworks */", to: "files", ofObject: frameworks)
                    } else {
                        let phase = id()
                        writer.insert(object: [
                            "\t\t\(phase) /* Frameworks */ = {", "\t\t\tisa = PBXFrameworksBuildPhase;", "\t\t\tbuildActionMask = 2147483647;",
                            "\t\t\tfiles = (", "\t\t\t\t\(buildFile) /* \(product) in Frameworks */,", "\t\t\t);",
                            "\t\t\trunOnlyForDeploymentPostprocessing = 0;", "\t\t};",
                        ], id: phase, isa: "PBXFrameworksBuildPhase")
                        try writer.append("\(phase) /* Frameworks */", to: "buildPhases", ofObject: target.id)
                    }
                }
            }
        }
        writer.removeObjects(doomed)
        let text = writer.text

        // Verify: the edited project declares exactly what was asked, and nothing removed is still referenced.
        let after = ProjectPackages(try PBXProjectFile(projectURL: file.projectURL, text: text))
        for spec in set where after.specs[spec.identity] != spec {
            let got = after.specs[spec.identity].map { "\($0.source), products \($0.products)" } ?? "missing"
            throw SochiError.editVerificationFailed("package \(spec.identity) reads back as \(got), expected \(spec.source), products \(spec.products)")
        }
        for identity in remove where after.specs[identity] != nil {
            throw SochiError.editVerificationFailed("package \(identity) is still declared")
        }
        for removed in doomed where text.contains(removed) {
            throw SochiError.editVerificationFailed("\(removed) is still referenced")
        }
        return text
    }

    static func refISA(_ spec: PackageSpec) -> String {
        if case .local = spec.source { return "XCLocalSwiftPackageReference" }
        return "XCRemoteSwiftPackageReference"
    }

    static func refComment(_ spec: PackageSpec) -> String { "\(refISA(spec)) \"\(spec.displayName)\"" }

    static func refLines(_ spec: PackageSpec, id: String) -> [String] {
        let q = PBXEditor.quote
        var lines = ["\t\t\(id) /* \(refComment(spec)) */ = {", "\t\t\tisa = \(refISA(spec));"]
        switch spec.source {
        case .local(let path):
            lines.append("\t\t\trelativePath = \(q(path));")
        case .remote(let url, let requirement):
            lines.append("\t\t\trepositoryURL = \(q(url));")
            // Keys sorted, as Xcode writes them.
            let fields: [(String, String)]
            switch requirement {
            case .upToNextMajor(let v): fields = [("kind", "upToNextMajorVersion"), ("minimumVersion", v)]
            case .upToNextMinor(let v): fields = [("kind", "upToNextMinorVersion"), ("minimumVersion", v)]
            case .exact(let v): fields = [("kind", "exactVersion"), ("version", v)]
            case .range(let a, let b): fields = [("kind", "versionRange"), ("maximumVersion", b), ("minimumVersion", a)]
            case .branch(let b): fields = [("branch", b), ("kind", "branch")]
            case .revision(let r): fields = [("kind", "revision"), ("revision", r)]
            }
            lines.append("\t\t\trequirement = {")
            lines += fields.map { "\t\t\t\t\($0.0) = \(q($0.1));" }
            lines.append("\t\t\t};")
        }
        return lines + ["\t\t};"]
    }
}

extension PBXTextWriter {
    /// Replaces a multi-line object's lines in place (keeping its position and ID).
    mutating func replaceObject(_ id: String, with objectLines: [String]) {
        guard let start = lines.firstIndex(where: { Self.objectID($0) == id }),
              let end = lines[start...].firstIndex(of: "\t\t};") else { return }
        lines.replaceSubrange(start...end, with: objectLines)
    }
}
