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
              sochi add target widget-extension Weather
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
        abstract: "Add a target from one of Xcode's templates, or of any product type (--type).",
        discussion: """
            With a template, sochi runs the selected Xcode's own File › New › Target template: the same files,
            Info.plist and settings Xcode would create, except that the Swift version, deployment target and
            versioning follow the app. List templates and their options with `sochi templates`.

            Without a template, --type takes any product type the selected Xcode defines, and --point an
            extension point identifier.

            Examples:
              sochi add target widget-extension Weather
              sochi add target widget-extension Weather --option includeLiveActivity=false
              sochi add target "Notification Service Extension" Rich
              sochi add target Shortcuts --type extensionkit-extension --point com.apple.appintents-extension
              sochi add target Kit --type framework --no-embed
            """)

    @Argument(help: "<template> <Name>, or just <Name> with --type.")
    var arguments: [String]

    @Option(name: .customLong("option"), help: ArgumentHelp("Template option, e.g. includeControl=false (repeatable).", valueName: "key=value"))
    var templateOptions: [String] = []

    @Option(help: ArgumentHelp("Product type, e.g. app-extension or com.apple.product-type.app-extension.", valueName: "type"))
    var type: String?

    @Option(help: ArgumentHelp("Extension point identifier, with --type.", valueName: "id"))
    var point: String?

    @Flag(help: "Don't embed the product in the app (with --type).")
    var noEmbed = false

    @Option(help: "App target that hosts the new target (default: the app target).")
    var host: String?

    @OptionGroup var options: EditOptions

    func validate() throws {
        if type != nil {
            guard arguments.count == 1 else { throw ValidationError("With --type, pass only the target name.") }
        } else {
            guard arguments.count == 2 else {
                throw ValidationError("Pass a template and a name, e.g. sochi add target widget-extension Weather (see `sochi templates`).")
            }
            if point != nil || noEmbed { throw ValidationError("--point and --no-embed apply only with --type.") }
        }
    }

    func run() async throws {
        try await reportingErrors {
            let next = "Build with `sochi run`; automatic signing registers its bundle ID with Apple."
            if let type {
                let request = GenericTargetRequest(name: arguments[0], productType: type, extensionPoint: point, embed: !noEmbed)
                try await runPlan(options: options, success: "added target \(Terminal.bold(arguments[0]))", nextStep: next) {
                    try await ProjectEditor.planGenericTarget(request, path: options.path, host: host, force: options.force)
                }
                return
            }
            var parsed: [String: String] = [:]
            for option in templateOptions {
                let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw ValidationError("Options look like key=value, got '\(option)'") }
                parsed[parts[0]] = parts[1]
            }
            try await runPlan(options: options, success: "added target from \(Terminal.bold(arguments[0]))", nextStep: next) {
                try await ProjectEditor.planTemplateTarget(
                    template: arguments[0], name: arguments[1], options: parsed, path: options.path, host: host, force: options.force)
            }
        }
    }
}

struct Templates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the selected Xcode's target templates and their options.")

    func run() async throws {
        try await reportingErrors {
            Terminal.status("  \(Terminal.dim("reading Xcode templates…"))")
            let templates = try await ProjectEditor.listTemplates()
            Terminal.clearStatus()
            var category = ""
            for (template, options) in templates {
                if template.category != category {
                    category = template.category
                    Terminal.print(Terminal.bold(category))
                }
                let platform = template.platformFolder == "iOS" ? "" : Terminal.dim("  (\(template.platformFolder))")
                let name = template.slug(from: "iOS")
                let slug = name.count < 42 ? name.padding(toLength: 42, withPad: " ", startingAt: 0) : name + "  "
                Terminal.print("  \(slug)\(template.name)\(platform)")
                if !options.isEmpty { Terminal.print(Terminal.dim("    --option \(options.joined(separator: "  --option "))")) }
            }
            Terminal.print(Terminal.dim("\n\(templates.count) templates  ·  sochi add target <template> <Name>"))
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

// MARK: - sochi migrate

struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert a group-based project to synchronized folders (Xcode 16's format).",
        discussion: """
            Each group that mirrors a real folder becomes a synchronized folder. Files on disk a target didn't use
            become exceptions, and per-file compiler flags carry over, so every target builds exactly what it did
            before. Groups that can't be converted faithfully are left as they are, with the reason.

            Before writing anything, sochi builds the project as it is and as converted (device SDK, no signing)
            and refuses if the compiled sources or bundled files differ. The converted project needs Xcode 16+.
            """)

    @Option(name: .customLong("project"), help: "Project directory or .xcodeproj.")
    var path: String = "."

    @Flag(help: "Show what would change without writing.")
    var dryRun = false

    @Flag(help: "Skip the before/after build comparison (static checks still run).")
    var noVerify = false

    @Flag(help: "Convert even if the project looks generated (XcodeGen, Tuist).")
    var force = false

    func run() async throws {
        try await reportingErrors {
            Terminal.status("  \(Terminal.dim("analyzing groups…"))")
            let (plan, report) = try await Migration.plan(path: path, force: force)
            Terminal.clearStatus()
            for folder in report.converted {
                let targets = folder.targets.isEmpty ? Terminal.dim("no targets") : folder.targets.joined(separator: ", ")
                Terminal.print("\(Terminal.green("→")) \(Terminal.bold(folder.folder))/  \(Terminal.dim("·")) \(targets)")
                for target in folder.targets {
                    let exceptions = folder.exceptions[target] ?? []
                    let flags = folder.flags[target] ?? [:]
                    if !exceptions.isEmpty {
                        Terminal.print(Terminal.dim("    \(target) excludes: \(exceptions.joined(separator: ", "))"))
                    }
                    for (file, value) in flags.sorted(by: { $0.key < $1.key }) {
                        Terminal.print(Terminal.dim("    \(target) keeps flags for \(file): \(value)"))
                    }
                }
            }
            for skipped in report.skipped {
                Terminal.print("\(Terminal.yellow("·")) \(skipped.group) \(Terminal.dim("stays a group: \(skipped.reason)"))")
            }
            guard !plan.edits.isEmpty else {
                Terminal.success("nothing to convert")
                return
            }
            if dryRun {
                Terminal.print(Terminal.dim("dry run: no files written"))
                return
            }
            if !noVerify {
                let inventory = try await MigrationVerifier.verify(plan) { step in Terminal.status("  \(Terminal.dim(step + "…"))") }
                Terminal.clearStatus()
                Terminal.success("builds identically \(Terminal.dim("(\(inventory.sourceCount) compiled sources, \(inventory.productFileCount) bundled files across \(inventory.products.count) products)"))")
            }
            Terminal.status("  \(Terminal.dim("writing and verifying…"))")
            try await ProjectEditor.apply(plan)
            Terminal.clearStatus()
            Terminal.success("converted \(report.converted.count) folder\(report.converted.count == 1 ? "" : "s") \(Terminal.dim("· the project now needs Xcode 16 or later"))")
        }
    }
}
