import Foundation

/// A Swift package dependency as sochi tracks it: where it comes from, which versions are allowed, and which of its
/// products each target links. The same model is read from the Xcode project and from sochi.toml.
public struct PackageSpec: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case remote(url: String, requirement: Requirement)
        case local(path: String)
    }

    /// SwiftPM's version rules, as Xcode stores them.
    public enum Requirement: Equatable, Sendable {
        case upToNextMajor(String)
        case upToNextMinor(String)
        case exact(String)
        case range(String, String)
        case branch(String)
        case revision(String)
    }

    /// SwiftPM identity: the URL's or folder's last component, lowercased, without `.git`.
    public var identity: String
    public var source: Source
    /// Target name → product names (sorted).
    public var products: [String: [String]]

    public init(identity: String, source: Source, products: [String: [String]] = [:]) {
        self.identity = identity
        self.source = source
        self.products = products.mapValues { Array(Set($0)).sorted() }.filter { !$0.value.isEmpty }
    }

    public static func identity(of location: String) -> String {
        var last = location.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? location
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.lowercased()
    }

    /// The name Xcode shows (and writes in comments): the location's last component, case kept.
    public var displayName: String {
        switch source {
        case .remote(let url, _):
            var last = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? url
            if last.hasSuffix(".git") { last.removeLast(4) }
            return last
        case .local(let path): return path
        }
    }

    public var requirementDescription: String {
        switch source {
        case .local(let path): return path
        case .remote(_, let requirement):
            switch requirement {
            case .upToNextMajor(let v): return "from \(v)"
            case .upToNextMinor(let v): return "\(v) up to next minor"
            case .exact(let v): return "exactly \(v)"
            case .range(let a, let b): return "\(a)..<\(b)"
            case .branch(let b): return "branch \(b)"
            case .revision(let r): return "revision \(r.prefix(12))"
            }
        }
    }

    /// The same package with another target's products merged in.
    func adding(products extra: [String: [String]]) -> PackageSpec {
        var merged = products
        for (target, list) in extra { merged[target, default: []] += list }
        return PackageSpec(identity: identity, source: source, products: merged)
    }
}

// MARK: - sochi.toml

/// sochi.toml: sochi's readable project file. Today it declares Swift packages; the Xcode project stays in sync with it
/// (see PackageSync). Edits are block-level, so comments and other sections are left as they are.
public struct SochiConfig: Sendable {
    public static let fileName = "sochi.toml"
    public let url: URL
    public private(set) var text: String
    public private(set) var packages: [PackageSpec]

    public static func load(projectDirectory: URL) throws -> SochiConfig? {
        let url = projectDirectory.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try SochiConfig(url: url, text: text)
    }

    init(url: URL, text: String) throws {
        self.url = url
        self.text = text
        let root = try TOML.parse(text)
        packages = try (root["packages"]?.pairs ?? []).map { key, value in try Self.spec(key: key, value: value) }
    }

    public static func new(projectDirectory: URL) -> SochiConfig {
        let text = """
            # sochi.toml: your project's packages, kept in sync with the Xcode project by sochi.
            # Edit it by hand or with `sochi add package`; Package.resolved stays the lockfile.

            """
        return try! SochiConfig(url: projectDirectory.appendingPathComponent(fileName), text: text)
    }

    static func spec(key: String, value: TOMLValue) throws -> PackageSpec {
        func fail(_ message: String) -> TOML.ParseError { TOML.ParseError(line: 0, message: "packages.\(key): \(message)") }
        guard case .table = value else { throw fail("expected a table") }
        var products: [String: [String]] = [:]
        for (target, list) in value["products"]?.pairs ?? [] {
            products[target] = try (list.array ?? []).map { item in
                guard let name = item.string else { throw fail("products must be lists of names") }
                return name
            }
        }
        if let path = value["path"]?.string {
            return PackageSpec(identity: key.lowercased(), source: .local(path: path), products: products)
        }
        guard let url = value["url"]?.string else { throw fail("needs `url` or `path`") }
        let requirement: PackageSpec.Requirement
        if let v = value["from"]?.string { requirement = .upToNextMajor(v) }
        else if let v = value["minor"]?.string { requirement = .upToNextMinor(v) }
        else if let v = value["exact"]?.string { requirement = .exact(v) }
        else if let v = value["branch"]?.string { requirement = .branch(v) }
        else if let v = value["revision"]?.string { requirement = .revision(v) }
        else if let v = value["range"]?.string {
            let parts = v.components(separatedBy: "..<").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw fail("range looks like \"1.0.0..<2.0.0\"") }
            requirement = .range(parts[0], parts[1])
        } else { throw fail("needs one of from, minor, exact, range, branch, revision") }
        return PackageSpec(identity: key.lowercased(), source: .remote(url: url, requirement: requirement), products: products)
    }

    /// The `[packages.<identity>]` block sochi writes.
    static func block(for spec: PackageSpec) -> [String] {
        var lines = ["[packages.\(TOML.formatKey(spec.identity))]"]
        switch spec.source {
        case .local(let path): lines.append("path = \(TOML.quote(path))")
        case .remote(let url, let requirement):
            lines.append("url = \(TOML.quote(url))")
            switch requirement {
            case .upToNextMajor(let v): lines.append("from = \(TOML.quote(v))")
            case .upToNextMinor(let v): lines.append("minor = \(TOML.quote(v))")
            case .exact(let v): lines.append("exact = \(TOML.quote(v))")
            case .range(let a, let b): lines.append("range = \(TOML.quote("\(a)..<\(b)"))")
            case .branch(let b): lines.append("branch = \(TOML.quote(b))")
            case .revision(let r): lines.append("revision = \(TOML.quote(r))")
            }
        }
        let products = spec.products.keys.sorted().map { (key: $0, value: TOMLValue.array(spec.products[$0]!.map { .string($0) })) }
        lines.append("products = \(TOML.format(.table(products)))")
        return lines
    }

    /// Adds or replaces a package's entry, leaving everything else in the file untouched.
    public mutating func set(_ spec: PackageSpec) throws {
        var lines = text.components(separatedBy: "\n")
        if let range = Self.entryRange(spec.identity, in: lines) {
            let inline = !lines[range.lowerBound].hasPrefix("[")
            lines.replaceSubrange(range, with: inline
                ? ["\(TOML.formatKey(spec.identity)) = \(TOML.format(Self.inlineValue(spec)))"] : Self.block(for: spec))
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += Self.block(for: spec) + [""]
        }
        try reload(lines.joined(separator: "\n"))
    }

    public mutating func remove(_ identity: String) throws {
        var lines = text.components(separatedBy: "\n")
        guard let range = Self.entryRange(identity, in: lines) else { return }
        lines.removeSubrange(range)
        // Collapse the blank line left behind.
        if range.lowerBound < lines.count, range.lowerBound > 0,
           lines[range.lowerBound].isEmpty, lines[range.lowerBound - 1].isEmpty { lines.remove(at: range.lowerBound) }
        try reload(lines.joined(separator: "\n"))
    }

    public func write() throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private mutating func reload(_ newText: String) throws {
        let parsed = try SochiConfig(url: url, text: newText)
        text = parsed.text
        packages = parsed.packages
    }

    static func inlineValue(_ spec: PackageSpec) -> TOMLValue {
        let block = block(for: spec).dropFirst()
        let parsed = try? TOML.parse(block.joined(separator: "\n"))
        return parsed ?? .table([])
    }

    /// Lines of a package's entry: a `[packages.x]` block (up to the next header, minus trailing blank lines), or a
    /// `x = { … }` line inside `[packages]`.
    static func entryRange(_ identity: String, in lines: [String]) -> Range<Int>? {
        let names = [identity, "\"\(identity)\""]
        if let start = lines.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return names.contains { t.lowercased() == "[packages.\($0)]" }
        }) {
            var end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            return start..<end
        }
        guard let section = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[packages]" }) else { return nil }
        for index in (section + 1)..<lines.count {
            let t = lines[index].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }
            if names.contains(where: { t.lowercased().hasPrefix("\($0) =") || t.lowercased().hasPrefix("\($0)=") }) { return index..<(index + 1) }
        }
        return nil
    }
}
