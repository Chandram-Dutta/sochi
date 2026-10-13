import Foundation

/// What a build actually consumed and produced: the ground truth a migration must preserve.
public struct BuildInventory: Equatable, Sendable {
    /// Target → source files compiled (paths relative to the project directory).
    public var sources: [String: Set<String>] = [:]
    /// Product (e.g. `App.app`) → files inside it.
    public var products: [String: Set<String>] = [:]

    public var sourceCount: Int { sources.values.reduce(0) { $0 + $1.count } }
    public var productFileCount: Int { products.values.reduce(0) { $0 + $1.count } }

    /// Human-readable differences from another inventory, empty when they match.
    public func differences(from other: BuildInventory) -> [String] {
        var result: [String] = []
        for target in Set(sources.keys).union(other.sources.keys).sorted() {
            let (before, after) = (other.sources[target] ?? [], sources[target] ?? [])
            for path in before.subtracting(after).sorted() { result.append("\(target): no longer compiles \(path)") }
            for path in after.subtracting(before).sorted() { result.append("\(target): now compiles \(path)") }
        }
        for product in Set(products.keys).union(other.products.keys).sorted() {
            let (before, after) = (other.products[product] ?? [], products[product] ?? [])
            for path in before.subtracting(after).sorted() { result.append("\(product): no longer contains \(path)") }
            for path in after.subtracting(before).sorted() { result.append("\(product): now contains \(path)") }
        }
        return result
    }
}

/// Builds a project before and after a migration (all targets, device SDK, no signing) and compares inventories.
public enum MigrationVerifier {
    public static func verify(_ plan: EditPlan, onStep: @Sendable (String) -> Void) async throws -> BuildInventory {
        guard let edit = plan.edits.first(where: { $0.url.lastPathComponent == "project.pbxproj" }) else { return BuildInventory() }
        let project = plan.projectURL
        let directory = project.deletingLastPathComponent()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-migrate-\(UUID().uuidString)")
        // The converted copy sits next to the original so every relative path resolves exactly the same.
        let candidate = directory.appendingPathComponent(".sochi-migrate-\(UUID().uuidString.prefix(8)).xcodeproj")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: candidate)
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try edit.updated.write(to: candidate.appendingPathComponent("project.pbxproj"))

        onStep("building the project as it is")
        let before = try await inventory(project: project, root: directory, scratch: scratch.appendingPathComponent("before"))
        onStep("building the converted project")
        let after = try await inventory(project: candidate, root: directory, scratch: scratch.appendingPathComponent("after"))
        let differences = after.differences(from: before)
        guard differences.isEmpty else { throw SochiError.migrationChangesBuild(differences) }
        return after
    }

    static func inventory(project: URL, root: URL, scratch: URL) async throws -> BuildInventory {
        let collector = InventoryCollector(root: root.standardizedFileURL.path)
        let status = try await Shell.stream([
            "xcodebuild", "build", "-project", project.path, "-alltargets", "-sdk", "iphoneos",
            "CODE_SIGNING_ALLOWED=NO", "SYMROOT=\(scratch.appendingPathComponent("build").path)",
            "OBJROOT=\(scratch.appendingPathComponent("obj").path)",
        ], cwd: root) { collector.consume($0) }
        guard status == 0 else { throw SochiError.migrationBaselineFailed(collector.errors) }

        var inventory = BuildInventory(sources: collector.sources)
        let products = scratch.appendingPathComponent("build")
        for configuration in (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [] {
            for product in (try? FileManager.default.contentsOfDirectory(at: configuration, includingPropertiesForKeys: nil)) ?? []
            where !product.pathExtension.isEmpty && product.pathExtension != "swiftmodule" {
                var files = Set<String>()
                let walker = FileManager.default.enumerator(at: product, includingPropertiesForKeys: [.isDirectoryKey])
                while let url = walker?.nextObject() as? URL {
                    let relative = url.path.replacingOccurrences(of: product.path + "/", with: "")
                    guard !relative.hasPrefix("_CodeSignature"), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                    else { continue }
                    files.insert(relative)
                }
                inventory.products[product.lastPathComponent] = files
            }
        }
        return inventory
    }
}

/// Parses xcodebuild output for compiled sources per target. Lines arrive on one background thread.
final class InventoryCollector: @unchecked Sendable {
    let root: String
    var sources: [String: Set<String>] = [:]
    var errors: [String] = []
    private static let sourceExtensions: Set<String> = ["swift", "c", "m", "mm", "cpp", "cc", "cxx", "metal", "s"]

    init(root: String) { self.root = root + "/" }

    func consume(_ line: String) {
        if case .diagnostic(let d) = BuildLog.parse(line), d.severity == .error, errors.count < 20 { errors.append(d.message) }
        guard line.hasPrefix("SwiftCompile ") || line.hasPrefix("CompileC "),
              let target = line.firstMatch(of: #/\(in target '([^']+)'/#).map({ String($0.1) }) else { return }
        for token in Self.tokens(line) where token.hasPrefix(root) {
            let path = String(token.dropFirst(root.count))
            if Self.sourceExtensions.contains((path as NSString).pathExtension.lowercased()) {
                sources[target, default: []].insert(path)
            }
        }
    }

    /// Splits a command line on unescaped spaces, unescaping `\ `.
    static func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == " " { if !current.isEmpty { result.append(current); current = "" } }
            else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
