import ArgumentParser
import Foundation
import SochiKit

@main
struct Sochi: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sochi",
        abstract: "Build and run Apple platform apps without opening Xcode.",
        version: "0.0.1",
        subcommands: [Run.self, Build.self, Add.self, Remove.self, CapabilitiesCommand.self, EntitlementsCommand.self,
                      Devices_.self, Sims.self, Doctor.self]
    )
}

struct SessionOptions: ParsableArguments {
    @Argument(help: "Project directory, .xcodeproj, or .xcworkspace.")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Scheme to build (default: the app scheme).")
    var scheme: String?

    @Option(name: .shortAndLong, help: "Device name or UDID (default: the connected device).")
    var device: String?

    @Flag(help: "Run on a simulator instead of a physical device.")
    var sim = false

    @Option(name: .shortAndLong, help: "Build configuration.")
    var configuration: String = "Debug"

    @Option(help: ArgumentHelp(
        "Development team ID or name; overrides the project's and is remembered. `auto` forgets it. Also: SOCHI_TEAM.",
        valueName: "team"))
    var team: String?

    @Flag(help: "Disable shortcuts for this run: always reinstall the app. Remembered choices still apply.")
    var fresh = false

    func resolve() async throws -> Session {
        Terminal.status("  \(Terminal.dim("resolving project…"))")
        let session = try await Session.resolve(
            path: path, scheme: scheme, device: device, simulator: sim, configuration: configuration,
            team: team ?? ProcessInfo.processInfo.environment["SOCHI_TEAM"], fresh: fresh)
        Terminal.clearStatus()

        func mark(_ source: ChoiceSource?) -> String { source == .saved ? Terminal.dim(" (saved)") : "" }
        let team = session.developmentTeam.map { Terminal.dim(" · team \($0)") + mark(session.teamSource) } ?? ""
        Terminal.print(
            "\(Terminal.bold("sochi")) \(Terminal.dim("v\(Sochi.configuration.version)"))  "
                + "\(session.project.name) › \(Terminal.bold(session.scheme))\(mark(session.schemeSource)) "
                + Terminal.dim("· \(session.configuration) · \(session.destination.summary)") + team)
        return session
    }
}

/// Builds with live progress and diagnostics. Throws a failure exit code if the build fails.
func buildWithProgress(_ session: inout Session) async throws {
    let renderer = BuildRenderer()
    let clock = ContinuousClock()
    let start = clock.now
    Terminal.status("  \(Terminal.dim("building…"))")
    let ok = try await session.buildResolving(onEvent: renderer.handle) { reason in
        renderer.dropDeferred()
        Terminal.clearStatus()
        Terminal.print("\(Terminal.cyan("↻")) \(reason)")
    }
    let elapsed = (clock.now - start).short

    if ok {
        let count = renderer.warningCount
        let warnings = count > 0 ? Terminal.yellow(", \(count) warning\(count == 1 ? "" : "s")") : ""
        Terminal.success("built in \(Terminal.bold(elapsed)) \(Terminal.dim("(\(renderer.taskCount) tasks)"))\(warnings)")
    } else {
        renderer.flushDeferred()
        renderer.dumpTailIfUnexplained()
        let errors = renderer.errorCount == 1 ? "1 error" : "\(renderer.errorCount) errors"
        Terminal.failure("build failed in \(elapsed) \(Terminal.dim("(\(errors))"))")
        throw ExitCode.failure
    }
}

/// Reports domain errors without ArgumentParser's usage dump.
func reportingErrors(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as SochiError {
        Terminal.clearStatus()
        Terminal.failure(error.description)
        throw ExitCode.failure
    } catch let error as ProcessError {
        Terminal.clearStatus()
        Terminal.failure(error.description)
        throw ExitCode.failure
    }
}
