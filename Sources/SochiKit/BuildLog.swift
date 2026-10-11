import Foundation

public struct Diagnostic: Sendable, Hashable {
    public enum Severity: String, Sendable { case error, warning, note }

    public let severity: Severity
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(severity: Severity, file: String? = nil, line: Int? = nil, column: Int? = nil, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }
}

public enum BuildEvent: Sendable, Equatable {
    /// A build task started, e.g. `SwiftCompile` of `ContentView.swift` in target `App`.
    case task(kind: String, subject: String, target: String?)
    case diagnostic(Diagnostic)
    case succeeded
    case failed
    case output(String)
}

/// Turns raw `xcodebuild` output lines into structured events.
public enum BuildLog {
    public static func parse(_ line: String) -> BuildEvent {
        if line == "** BUILD SUCCEEDED **" { return .succeeded }
        if line == "** BUILD FAILED **" { return .failed }
        if let diagnostic = parseDiagnostic(line) { return .diagnostic(diagnostic) }
        if let task = parseTask(line) { return task }
        return .output(line)
    }

    static func parseDiagnostic(_ line: String) -> Diagnostic? {
        if let m = line.wholeMatch(of: #/(/[^:]+):(\d+):(\d+): (error|warning|note): (.*)/#) {
            return Diagnostic(
                severity: Diagnostic.Severity(rawValue: String(m.4))!,
                file: String(m.1), line: Int(m.2), column: Int(m.3), message: String(m.5))
        }
        if let m = line.wholeMatch(of: #/(/[^:]+): (error|warning|note): (.*)/#) {
            return Diagnostic(severity: Diagnostic.Severity(rawValue: String(m.2))!, file: String(m.1), message: String(m.3))
        }
        if let m = line.wholeMatch(of: #/(?:xcodebuild: )?(error|warning): (.*)/#) {
            return Diagnostic(severity: Diagnostic.Severity(rawValue: String(m.1))!, message: String(m.2))
        }
        return nil
    }

    /// Task lines look like `SwiftCompile normal arm64 /path/Foo.swift (in target 'App' from project 'App')`.
    static func parseTask(_ line: String) -> BuildEvent? {
        guard let m = line.wholeMatch(of: #/([A-Z][A-Za-z]+) (.*) \(in target '([^']+)'.*\)/#) else { return nil }
        let body = String(m.2).replacingOccurrences(of: "\\ ", with: " ")
        let subject = body.split(separator: "/").last.map(String.init) ?? body
        return .task(kind: String(m.1), subject: subject.trimmingCharacters(in: .whitespaces), target: String(m.3))
    }
}

/// Build failures sochi knows how to recover from by re-resolving a choice and retrying.
public enum BuildFailure: Equatable, Sendable {
    /// The scheme doesn't exist (e.g. a remembered scheme was renamed or deleted).
    case missingScheme
    /// Device signing needs a team and the project has none.
    case needsTeam
    case other

    public static func classify(_ diagnostic: Diagnostic) -> BuildFailure {
        guard diagnostic.severity == .error else { return .other }
        if diagnostic.message.contains("does not contain a scheme named") { return .missingScheme }
        if diagnostic.message.contains("requires a development team") { return .needsTeam }
        return .other
    }
}
