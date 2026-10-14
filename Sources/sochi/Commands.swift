import ArgumentParser
import Foundation
import SochiKit

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build, install, and launch the app, streaming its output.")

    @OptionGroup var options: SessionOptions

    func run() async throws {
        try await reportingErrors {
            try await syncPackagesIfConfigured(options.path)
            var session = try await options.resolve()

            // Settings are never cached: query them fresh, hidden behind the build.
            // Same for booting a simulator (a no-op for devices).
            let initial = session
            async let prepared: Void = initial.prepare()
            async let settings = initial.appProduct()
            try await buildWithProgress(&session)

            let clock = ContinuousClock()
            let start = clock.now
            Terminal.status("  \(Terminal.dim("preparing \(session.destination.name)…"))")
            // Re-query if the concurrent query failed or the build switched to a re-detected scheme.
            let product: AppProduct
            if let fetched = try? await settings, session.scheme == initial.scheme {
                product = fetched
            } else {
                product = try await session.appProduct()
            }
            try await prepared
            Terminal.status("  \(Terminal.dim("installing on \(session.destination.name)…"))")
            let outcome = try await session.installIfNeeded(product)
            Terminal.clearStatus()
            switch outcome {
            case .installed:
                Terminal.success("installed \(Terminal.bold(product.bundleIdentifier)) in \((clock.now - start).short)")
            case .upToDate:
                Terminal.success("\(Terminal.bold(product.bundleIdentifier)) already up to date on device \(Terminal.dim("(checked in \((clock.now - start).short))"))")
            }
            Terminal.print(Terminal.dim("  ── app output · ctrl-c to stop ──"))

            Interrupt.trap()
            _ = try await session.launchAttached(product)
            if Interrupt.received { Terminal.print(); Terminal.print(Terminal.dim("  stopped")) }
        }
    }
}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build the app for the connected device (or --sim).")

    @OptionGroup var options: SessionOptions

    func run() async throws {
        try await reportingErrors {
            try await syncPackagesIfConfigured(options.path)
            var session = try await options.resolve()
            try await buildWithProgress(&session)
        }
    }
}

struct Devices_: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "List paired physical devices.")

    func run() async throws {
        try await reportingErrors {
            let devices = try await Devices.list()
            if devices.isEmpty { Terminal.print(Terminal.dim("No paired devices. Connect one and trust this Mac.")) }
            for d in devices {
                let state = d.isReachable ? Terminal.green("● \(d.status)") : Terminal.dim("○ unavailable")
                let devMode = d.developerModeEnabled != false ? "" : Terminal.yellow("  developer mode off")
                Terminal.print(
                    "  \(d.name.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                        + Terminal.dim("\(d.model) · \(d.platform) \(d.osVersion) · \(d.udid)") + "  \(state)\(devMode)")
            }
        }
    }
}

struct Sims: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available simulators.")

    func run() async throws {
        try await reportingErrors {
            var current: Runtime?
            for sim in try await Simulators.list() {
                if sim.runtime != current {
                    current = sim.runtime
                    Terminal.print(Terminal.bold("\(sim.runtime)"))
                }
                let state = sim.isBooted ? Terminal.green("● booted") : ""
                Terminal.print("  \(sim.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(Terminal.dim(sim.udid))  \(state)")
            }
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the toolchain and environment.")

    func run() async throws {
        var healthy = true
        func check(_ label: String, _ body: () async throws -> String) async {
            do {
                Terminal.success("\(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(Terminal.dim(try await body()))")
            } catch {
                healthy = false
                Terminal.failure("\(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \("\(error)")")
            }
        }
        func firstLine(_ s: String) -> String { s.split(separator: "\n").first.map(String.init) ?? s }

        await check("xcode") {
            let path = try await Shell.run(["xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let version = try await Shell.run(["xcodebuild", "-version"]).split(separator: "\n").joined(separator: ", ")
            return "\(version) at \(path)"
        }
        await check("swift") { firstLine(try await Shell.run(["swift", "--version"])) }
        await check("devices") {
            let devices = try await Devices.list()
            let reachable = devices.filter(\.isReachable).map(\.name)
            return "\(devices.count) paired · " + (reachable.isEmpty ? "none connected" : "connected: \(reachable.joined(separator: ", "))")
        }
        await check("teams") {
            let teams = try await Signing.teams()
            guard !teams.isEmpty else { throw SochiError.noSigningTeam }
            return teams.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        }
        await check("simulators") {
            let sims = try await Simulators.list()
            let runtimes = Set(sims.map(\.runtime)).sorted(by: >).map(\.description)
            guard !runtimes.isEmpty else { throw SochiError.noSimulator(platform: "any") }
            return "\(sims.count) devices · \(runtimes.joined(separator: ", ")) · \(sims.filter(\.isBooted).count) booted"
        }
        await check("cache") { Paths.cacheRoot.path }
        if !healthy { throw ExitCode.failure }
    }
}

/// Lets `run` clean up the app after ctrl-c. A real handler (unlike SIG_IGN) resets to default in
/// child processes, so simctl still dies on ctrl-c and hands control back to us.
enum Interrupt {
    nonisolated(unsafe) private static var flag: sig_atomic_t = 0

    static var received: Bool { flag != 0 }

    static func trap() {
        signal(SIGINT) { _ in Interrupt.flag = 1 }
    }
}
