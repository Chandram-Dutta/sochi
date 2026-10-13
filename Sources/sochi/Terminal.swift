import Foundation
import SochiKit

/// Minimal styled output. UI goes to stderr so the app's own stdout stays clean and pipeable.
enum Terminal {
    static let isInteractive = isatty(STDERR_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func style(_ text: String, _ code: String) -> String {
        isInteractive ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ s: String) -> String { style(s, "1") }
    static func dim(_ s: String) -> String { style(s, "2") }
    static func red(_ s: String) -> String { style(s, "31") }
    static func green(_ s: String) -> String { style(s, "32") }
    static func yellow(_ s: String) -> String { style(s, "33") }
    static func cyan(_ s: String) -> String { style(s, "36") }

    static func print(_ line: String = "") {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Overwrites the current line with a transient status. No-op when not interactive.
    static func status(_ line: String) {
        guard isInteractive else { return }
        let width = 100
        let clipped = line.count > width ? String(line.prefix(width - 1)) + "…" : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(clipped)".utf8))
    }

    static func clearStatus() {
        guard isInteractive else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }

    static func success(_ message: String) { print("\(green("✓")) \(message)") }
    static func failure(_ message: String) { print("\(red("✗")) \(message)") }
}

extension Duration {
    var short: String {
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return seconds < 1 ? "\(Int(seconds * 1000))ms" : String(format: "%.1fs", seconds)
    }
}

/// Renders a streaming build: a transient status line for tasks, persistent diagnostics with source context.
/// Events arrive on a single background thread; summary fields are read only after the build returns.
final class BuildRenderer: @unchecked Sendable {
    private(set) var taskCount = 0
    private(set) var errorCount = 0
    private(set) var warningCount = 0
    /// Error messages seen, for hints after a failed build.
    private(set) var errorMessages: [String] = []
    private var seen = Set<Diagnostic>()
    /// Errors a retry may resolve; shown only if the build ultimately fails.
    private var deferred: [Diagnostic] = []
    private var tail: [String] = []

    func handle(_ event: BuildEvent) {
        switch event {
        case .task(let kind, let subject, let target):
            taskCount += 1
            let where_ = target.map { Terminal.dim(" (\($0))") } ?? ""
            Terminal.status("  \(Terminal.dim(kind)) \(subject)\(where_)")
        case .diagnostic(let diagnostic):
            guard diagnostic.severity != .note, seen.insert(diagnostic).inserted else { return }
            if BuildFailure.classify(diagnostic) != .other {
                deferred.append(diagnostic)
                return
            }
            show(diagnostic)
        case .output(let line):
            tail.append(line)
            if tail.count > 40 { tail.removeFirst() }
        case .succeeded, .failed:
            Terminal.clearStatus()
        }
    }

    func dropDeferred() {
        deferred.removeAll()
        seen.removeAll()
    }

    func flushDeferred() {
        deferred.forEach(show)
        deferred.removeAll()
    }

    private func show(_ diagnostic: Diagnostic) {
        if diagnostic.severity == .error { errorCount += 1; errorMessages.append(diagnostic.message) } else { warningCount += 1 }
        Terminal.clearStatus()
        render(diagnostic)
    }

    /// When a build fails without a parseable error, the raw tail is the only clue.
    func dumpTailIfUnexplained() {
        guard errorCount == 0 else { return }
        Terminal.print(Terminal.dim(tail.joined(separator: "\n")))
    }

    private func render(_ d: Diagnostic) {
        let label = d.severity == .error ? Terminal.red(Terminal.bold("error")) : Terminal.yellow(Terminal.bold("warning"))
        Terminal.print("\(label): \(Terminal.bold(d.message))")
        guard let file = d.file else { return }
        var location = relative(file)
        if let line = d.line { location += ":\(line)" + (d.column.map { ":\($0)" } ?? "") }
        Terminal.print("  \(Terminal.dim("at")) \(Terminal.cyan(location))")
        if let line = d.line, let source = sourceLine(file, line) {
            let gutter = "\(line) | "
            Terminal.print("  " + Terminal.dim(gutter) + source)
            if let column = d.column, column > 0 {
                let pad = String(repeating: " ", count: gutter.count + column - 1)
                Terminal.print("  " + pad + (d.severity == .error ? Terminal.red("^") : Terminal.yellow("^")))
            }
        }
        Terminal.print()
    }

    private func relative(_ path: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath + "/"
        return path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
    }

    private func sourceLine(_ path: String, _ number: Int) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard number >= 1, number <= lines.count else { return nil }
        return String(lines[number - 1])
    }
}
