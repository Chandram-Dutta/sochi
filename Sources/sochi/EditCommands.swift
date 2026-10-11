import ArgumentParser
import Foundation
import SochiKit

struct EditOptions: ParsableArguments {
    @Option(name: .customLong("project"), help: "Project directory, .xcodeproj, or .xcworkspace.")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Target to edit (default: the app target).")
    var target: String?

    @Flag(help: "Show the changes without writing them.")
    var dryRun = false

    @Flag(help: "Edit even if the project looks generated (XcodeGen, Tuist).")
    var force = false
}

private let capabilityList = Capabilities.all
    .map { "  \($0.name.padding(toLength: 30, withPad: " ", startingAt: 0))\($0.title)\($0.hint.map { "  (e.g. \($0))" } ?? "")" }
    .joined(separator: "\n")

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a capability to a target, like Xcode's + Capability.",
        discussion: "Capabilities:\n\(capabilityList)\n\nThe next build registers it with Apple through automatic signing.")

    @Argument(help: "Capability name, e.g. push or app-groups.")
    var capability: String

    @Argument(help: "Values for list capabilities, e.g. group IDs or domains.")
    var values: [String] = []

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors { try await editCapability(capability, values: values, remove: false, options: options) }
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a capability (or specific values of one) from a target.",
        discussion: "Capabilities:\n\(capabilityList)")

    @Argument(help: "Capability name.")
    var capability: String

    @Argument(help: "Remove only these values, keeping the rest.")
    var values: [String] = []

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors { try await editCapability(capability, values: values, remove: true, options: options) }
    }
}

struct CapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities", abstract: "Show a target's capabilities and the ones sochi can add.")

    @Option(name: .customLong("project"), help: "Project directory, .xcodeproj, or .xcworkspace.")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Target to inspect (default: the app target).")
    var target: String?

    func run() async throws {
        try await reportingErrors {
            Terminal.status("  \(Terminal.dim("reading project…"))")
            let (target, files) = try await ProjectEditor.entitlements(path: path, target: target)
            Terminal.clearStatus()
            Terminal.print(Terminal.bold(target))
            if files.isEmpty { Terminal.print(Terminal.dim("  no entitlements file")) }
            var enabled = Set<String>()
            for (url, entitlements) in files {
                Terminal.print(Terminal.dim("  \(relativePath(url))"))
                let (known, unknown) = Capabilities.detect(in: entitlements)
                for (capability, values) in known {
                    enabled.insert(capability.name)
                    let detail = values.isEmpty ? "" : Terminal.dim("  \(values.joined(separator: ", "))")
                    Terminal.print("  \(Terminal.green("●")) \(capability.title)\(detail)")
                }
                for key in unknown { Terminal.print("  \(Terminal.green("●")) \(Terminal.dim(key))") }
            }
            let available = Capabilities.all.filter { !enabled.contains($0.name) }
            if !available.isEmpty {
                Terminal.print()
                Terminal.print(Terminal.dim("available: \(available.map(\.name).joined(separator: ", "))  ·  sochi add <name>"))
            }
        }
    }
}

private func editCapability(_ name: String, values: [String], remove: Bool, options: EditOptions) async throws {
    let capability = try Capabilities.named(name)
    Terminal.status("  \(Terminal.dim("reading project…"))")
    let plan = try await ProjectEditor.planCapability(
        capability, values: values, remove: remove, path: options.path, target: options.target, force: options.force)
    Terminal.clearStatus()

    for note in plan.notes { Terminal.print(Terminal.dim("  \(note)")) }
    guard !plan.edits.isEmpty else {
        Terminal.success("nothing to change")
        return
    }
    for edit in plan.edits { Terminal.print(try await diff(edit)) }

    if options.dryRun {
        Terminal.print(Terminal.dim("dry run: no files written"))
        return
    }
    Terminal.status("  \(Terminal.dim("writing and verifying…"))")
    try await ProjectEditor.apply(plan)
    Terminal.clearStatus()
    Terminal.success("\(remove ? "removed" : "added") \(Terminal.bold(capability.title)) \(remove ? "from" : "to") \(plan.target)")
    if !remove {
        Terminal.print(Terminal.dim("  Apple's side (App ID, profile) is set up by automatic signing on the next `sochi run`."))
    }
}

/// A colored unified diff of one planned edit, via the system `diff`.
private func diff(_ edit: EditPlan.FileEdit) async throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-diff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = dir.appendingPathComponent("a")
    let after = dir.appendingPathComponent("b")
    try (edit.original ?? Data()).write(to: before)
    try edit.updated.write(to: after)

    let path = relativePath(edit.url)
    let lines = Box()
    _ = try await Shell.stream([
        "diff", "-u", "--label", edit.original == nil ? "/dev/null" : "a/\(path)", "--label", "b/\(path)",
        before.path, after.path,
    ]) { lines.append($0) }
    return lines.value.map { line in
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Terminal.bold(line) }
        if line.hasPrefix("+") { return Terminal.green(line) }
        if line.hasPrefix("-") { return Terminal.red(line) }
        if line.hasPrefix("@@") { return Terminal.cyan(line) }
        return Terminal.dim(line)
    }.joined(separator: "\n")
}

private func relativePath(_ url: URL) -> String {
    let cwd = FileManager.default.currentDirectoryPath + "/"
    return url.path.hasPrefix(cwd) ? String(url.path.dropFirst(cwd.count)) : url.path
}

/// Collects lines from a streaming callback; reads happen only after the stream completes.
private final class Box: @unchecked Sendable {
    var value: [String] = []
    func append(_ line: String) { value.append(line) }
}
