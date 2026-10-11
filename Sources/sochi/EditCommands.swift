import ArgumentParser
import Foundation
import SochiKit

/// Options shared by commands that edit the project.
struct EditOptions: ParsableArguments {
    @Option(name: .customLong("project"), help: "Project directory, .xcodeproj, or .xcworkspace.")
    var path: String = "."

    @Flag(help: "Show the changes without writing them.")
    var dryRun = false

    @Flag(help: "Edit even if the project looks generated (XcodeGen, Tuist).")
    var force = false
}

// MARK: - sochi add

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a capability or a target, like Xcode's + Capability and New Target.",
        discussion: """
            Examples:
              sochi add capability push-notifications
              sochi add capability associated-domains applinks:example.com
              sochi add target Weather --type app-extension --point com.apple.widgetkit-extension
            """,
        subcommands: [AddCapability.self, AddTarget.self])
}

struct AddCapability: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capability",
        abstract: "Add a capability to a target.",
        discussion: """
            Capabilities come from Apple's catalog in the selected Xcode; list them with `sochi capabilities --all`.
            Names are Apple's (e.g. push-notifications, sign-in-with-apple, healthkit), its IDs (PUSH_NOTIFICATIONS),
            or any unambiguous part (push). The next build registers it with Apple through automatic signing.

            Examples:
              sochi add capability push-notifications
              sochi add capability associated-domains applinks:example.com
              sochi add capability network-extensions packet-tunnel-provider
            """)

    @Argument(help: "Capability, e.g. push-notifications or healthkit.")
    var name: String

    @Argument(help: "Values for list capabilities, e.g. group IDs or domains.")
    var values: [String] = []

    @Option(name: .shortAndLong, help: "Target to edit (default: the app target).")
    var target: String?

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors {
            try await runPlan(options: options, success: "added \(Terminal.bold(name))", nextStep: signingHint) {
                try await ProjectEditor.planCapability(
                    name, values: values, remove: false, path: options.path, target: target, force: options.force)
            }
        }
    }
}

struct AddTarget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "target",
        abstract: "Add a target of any product type the selected Xcode defines, embedded in the app.",
        discussion: """
            The product type and extension point are Apple's own identifiers, so every type Xcode supports works
            without sochi knowing about it. How the product is embedded comes from Xcode's build specifications.

            Examples:
              sochi add target Weather --type app-extension --point com.apple.widgetkit-extension
              sochi add target Shortcuts --type extensionkit-extension --point com.apple.appintents-extension
              sochi add target Rich --type app-extension --point com.apple.usernotifications.service
              sochi add target Kit --type framework --no-embed
            """)

    @Argument(help: "Target name; also its folder and the suffix of its bundle ID.")
    var name: String

    @Option(help: ArgumentHelp("Product type, e.g. app-extension or com.apple.product-type.app-extension.", valueName: "type"))
    var type: String

    @Option(help: ArgumentHelp("Extension point identifier, for extension product types.", valueName: "id"))
    var point: String?

    @Flag(help: "Don't embed the product in the app.")
    var noEmbed = false

    @Option(help: "App target that hosts the new target (default: the app target).")
    var host: String?

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors {
            let request = GenericTargetRequest(name: name, productType: type, extensionPoint: point, embed: !noEmbed)
            try await runPlan(
                options: options, success: "added target \(Terminal.bold(name))",
                nextStep: "Build with `sochi run`; automatic signing registers its bundle ID with Apple."
            ) {
                try await ProjectEditor.planGenericTarget(request, path: options.path, host: host, force: options.force)
            }
        }
    }
}

// MARK: - sochi remove

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a capability.",
        discussion: "Example:\n  sochi remove capability app-groups group.com.example.old",
        subcommands: [RemoveCapability.self])
}

struct RemoveCapability: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capability",
        abstract: "Remove a capability (or specific values of one) from a target.",
        discussion: "Takes the same names as `sochi add capability`.")

    @Argument(help: "Capability name.")
    var name: String

    @Argument(help: "Remove only these values, keeping the rest.")
    var values: [String] = []

    @Option(name: .shortAndLong, help: "Target to edit (default: the app target).")
    var target: String?

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors {
            try await runPlan(options: options, success: "removed \(Terminal.bold(name))", nextStep: nil) {
                try await ProjectEditor.planCapability(
                    name, values: values, remove: true, path: options.path, target: target, force: options.force)
            }
        }
    }
}

// MARK: - sochi entitlements

struct EntitlementsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entitlements",
        abstract: "Show or edit any entitlement directly.",
        discussion: """
            Works for every entitlement, including ones sochi has no friendly name for.

            Examples:
              sochi entitlements
              sochi entitlements set com.apple.developer.healthkit true
              sochi entitlements add com.apple.security.application-groups group.com.example.shared
              sochi entitlements remove com.apple.developer.healthkit
            """,
        subcommands: [ShowEntitlements.self, SetEntitlement.self, AddEntitlementValues.self, RemoveEntitlement.self],
        defaultSubcommand: ShowEntitlements.self)
}

struct ShowEntitlements: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print a target's entitlements.")

    @Option(name: .customLong("project"), help: "Project directory, .xcodeproj, or .xcworkspace.")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Target (default: the app target).")
    var target: String?

    func run() async throws {
        try await reportingErrors {
            Terminal.status("  \(Terminal.dim("reading project…"))")
            let (target, files) = try await ProjectEditor.entitlements(path: path, target: target)
            Terminal.clearStatus()
            Terminal.print(Terminal.bold(target))
            if files.isEmpty { Terminal.print(Terminal.dim("  no entitlements file")) }
            for (url, entitlements) in files {
                Terminal.print(Terminal.dim("  \(relativePath(url))"))
                for key in entitlements.keys.sorted() {
                    Terminal.print("  \(key) = \(Terminal.cyan(describe(entitlements[key]!)))")
                }
            }
        }
    }
}

struct SetEntitlement: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set an entitlement. One value of true/false is a boolean, several values (or --array) an array.")

    @Argument(help: "Entitlement key.")
    var key: String

    @Argument(help: "Value(s).")
    var values: [String]

    @Flag(help: "Store as an array even with one value.")
    var array = false

    @Flag(help: "Store true/false as a string rather than a boolean.")
    var string = false

    @Option(name: .shortAndLong, help: "Target (default: the app target).")
    var target: String?

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors {
            let value: EntitlementValue
            if array || values.count > 1 {
                value = .array(values)
            } else if !string, ["true", "false"].contains(values[0].lowercased()) {
                value = .bool(values[0].lowercased() == "true")
            } else {
                value = .string(values[0])
            }
            try await runPlan(options: options, success: "set \(Terminal.bold(key))", nextStep: signingHint) {
                try await ProjectEditor.planEntitlements(
                    path: options.path, target: target, force: options.force, createIfMissing: true, label: key
                ) { current, _ in
                    var updated = current
                    updated[key] = value.object
                    return updated
                }
            }
        }
    }
}

struct AddEntitlementValues: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add values to an array entitlement, creating it if needed.")

    @Argument(help: "Entitlement key.")
    var key: String

    @Argument(help: "Values to add.")
    var values: [String]

    @Option(name: .shortAndLong, help: "Target (default: the app target).")
    var target: String?

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors {
            try await runPlan(options: options, success: "updated \(Terminal.bold(key))", nextStep: signingHint) {
                try await ProjectEditor.planEntitlements(
                    path: options.path, target: target, force: options.force, createIfMissing: true, label: key
                ) { current, _ in
                    guard current[key] == nil || current[key] is [Any] else { throw SochiError.notAnArray(key) }
                    let existing = current[key] as? [String] ?? []
                    var updated = current
                    updated[key] = existing + values.filter { !existing.contains($0) }
                    return updated
                }
            }
        }
    }
}

struct RemoveEntitlement: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove an entitlement, or only some values of an array entitlement.")

    @Argument(help: "Entitlement key.")
    var key: String

    @Argument(help: "Remove only these values.")
    var values: [String] = []

    @Option(name: .shortAndLong, help: "Target (default: the app target).")
    var target: String?

    @OptionGroup var options: EditOptions

    func run() async throws {
        try await reportingErrors {
            try await runPlan(options: options, success: "updated \(Terminal.bold(key))", nextStep: nil) {
                try await ProjectEditor.planEntitlements(
                    path: options.path, target: target, force: options.force, createIfMissing: false,
                    label: key, removing: true
                ) { current, _ in
                    var updated = current
                    if values.isEmpty {
                        updated[key] = nil
                    } else {
                        let remaining = (current[key] as? [String] ?? []).filter { !values.contains($0) }
                        updated[key] = remaining.isEmpty ? nil : remaining
                    }
                    return updated
                }
            }
        }
    }
}

/// A parsed command-line entitlement value (Sendable, unlike `Any`).
private enum EntitlementValue: Sendable {
    case bool(Bool)
    case string(String)
    case array([String])

    var object: Any {
        switch self {
        case .bool(let b): b
        case .string(let s): s
        case .array(let a): a
        }
    }
}

// MARK: - sochi capabilities

struct CapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Show a target's capabilities, or every capability Apple offers for iOS (--all).")

    @Option(name: .customLong("project"), help: "Project directory, .xcodeproj, or .xcworkspace.")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Target to inspect (default: the app target).")
    var target: String?

    @Flag(help: "List every iOS capability in Apple's catalog instead.")
    var all = false

    func run() async throws {
        try await reportingErrors {
            Terminal.status("  \(Terminal.dim("reading catalog…"))")
            let catalog = try await CapabilityCatalog.load(team: nil)
            if all {
                Terminal.clearStatus()
                for capability in catalog.available() {
                    let needsID = capability.entitlements(for: "IOS").contains { $0.values.contains(where: \.isPlaceholder) }
                    let marks = [needsID ? "needs ID" : nil, capability.needsApproval ? "needs Apple approval" : nil].compactMap { $0 }
                    Terminal.print("  \(capability.slug.padding(toLength: 44, withPad: " ", startingAt: 0))\(capability.name)"
                        + (marks.isEmpty ? "" : Terminal.dim("  (\(marks.joined(separator: ", ")))")))
                }
                for local in LocalCapability.all {
                    Terminal.print("  \(local.slug.padding(toLength: 44, withPad: " ", startingAt: 0))\(local.name)" + Terminal.dim("  (Xcode-only)"))
                }
                Terminal.print(Terminal.dim("\n\(catalog.available().count) from \(catalog.source.lastPathComponent)  ·  sochi add capability <name>"))
                return
            }
            Terminal.status("  \(Terminal.dim("reading project…"))")
            async let schema = EntitlementSchema.load()
            let (target, files) = try await ProjectEditor.entitlements(path: path, target: target)
            let titles = await schema
            Terminal.clearStatus()
            Terminal.print(Terminal.bold(target))
            if files.isEmpty { Terminal.print(Terminal.dim("  no entitlements file")) }
            for (url, entitlements) in files {
                Terminal.print(Terminal.dim("  \(relativePath(url))"))
                let (enabled, unclaimed) = catalog.detect(in: entitlements)
                for capability in enabled {
                    let lists = capability.entitlements(for: "IOS").compactMap { entitlements[$0.key] as? [String] }.flatMap { $0 }
                    let detail = lists.isEmpty ? "" : Terminal.dim("  \(lists.joined(separator: ", "))")
                    Terminal.print("  \(Terminal.green("●")) \(capability.name)\(detail)")
                }
                for key in unclaimed {
                    // Name keys no catalog entry claims from Xcode's own schema (e.g. Data Protection).
                    let name = LocalCapability.all.first { $0.key == key }?.name ?? titles[key]?.title
                    Terminal.print("  \(Terminal.green("●")) " + (name ?? Terminal.dim(key)))
                }
            }
            Terminal.print(Terminal.dim("\nsochi capabilities --all  ·  sochi add capability <name>"))
        }
    }
}

// MARK: - Shared

private let signingHint = "Apple's side (App ID, profile) is set up by automatic signing on the next `sochi run`."

/// Plans, shows the diff, then (unless dry-running) writes and verifies.
private func runPlan(
    options: EditOptions, success: String, nextStep: String?, plan makePlan: () async throws -> EditPlan
) async throws {
    Terminal.status("  \(Terminal.dim("reading project…"))")
    let plan = try await makePlan()
    Terminal.clearStatus()
    for note in plan.notes { Terminal.print(Terminal.dim("  \(note)")) }
    guard !plan.edits.isEmpty else {
        Terminal.success("nothing to change")
        return
    }
    for edit in plan.edits {
        if edit.original == nil, edit.url.pathExtension != "entitlements" {
            Terminal.print(Terminal.green("+ \(relativePath(edit.url))"))
        } else {
            Terminal.print(try await diff(edit))
        }
    }
    if options.dryRun {
        Terminal.print(Terminal.dim("dry run: no files written"))
        return
    }
    Terminal.status("  \(Terminal.dim("writing and verifying…"))")
    try await ProjectEditor.apply(plan)
    Terminal.clearStatus()
    Terminal.success("\(success) \(Terminal.dim("in \(plan.target)"))")
    if let nextStep { Terminal.print(Terminal.dim("  \(nextStep)")) }
}

private func describe(_ value: Any) -> String {
    switch value {
    case let b as Bool: return b ? "true" : "false"
    case let a as [Any]: return "[" + a.map(describe).joined(separator: ", ") + "]"
    case let d as [String: Any]: return "{" + d.keys.sorted().map { "\($0): \(describe(d[$0]!))" }.joined(separator: ", ") + "}"
    default: return "\(value)"
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
    let lines = LineBuffer()
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
private final class LineBuffer: @unchecked Sendable {
    var value: [String] = []
    func append(_ line: String) { value.append(line) }
}
