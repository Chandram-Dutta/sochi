import Foundation

public struct ProcessError: Error, CustomStringConvertible {
    public let command: [String]
    public let status: Int32
    public let output: String

    public var description: String {
        let cmd = command.joined(separator: " ")
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "`\(cmd)` exited with status \(status)"
            : "`\(cmd)` exited with status \(status):\n\(detail)"
    }
}

/// Thin wrapper over `Process`. Blocking work is offloaded to GCD so callers can stay async
/// without tying up the cooperative thread pool.
public enum Shell {
    /// Runs a command to completion and returns its stdout. Throws `ProcessError` on non-zero exit.
    @discardableResult
    public static func run(_ args: [String], cwd: URL? = nil) async throws -> String {
        try await offload { try runSync(args, cwd: cwd) }
    }

    /// Runs a command with stderr merged into stdout, delivering output line by line.
    /// Returns the exit status instead of throwing on failure.
    public static func stream(
        _ args: [String],
        cwd: URL? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        try await offload { try streamSync(args, cwd: cwd, onLine: onLine) }
    }

    /// Runs a command attached to this process's stdio. Returns the exit status.
    public static func exec(_ args: [String], cwd: URL? = nil) async throws -> Int32 {
        try await offload {
            let process = makeProcess(args, cwd: cwd)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    static func runSync(_ args: [String], cwd: URL?) throws -> String {
        let process = makeProcess(args, cwd: cwd)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain stderr concurrently so a full pipe can't deadlock the child.
        let errData = Box(Data())
        let group = DispatchGroup()
        let errHandle = stderr.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            errData.value = errHandle.readDataToEndOfFile()
            group.leave()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        let out = String(decoding: outData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let err = String(decoding: errData.value, as: UTF8.self)
            throw ProcessError(command: args, status: process.terminationStatus, output: err.isEmpty ? out : err)
        }
        return out
    }

    static func streamSync(_ args: [String], cwd: URL?, onLine: (String) -> Void) throws -> Int32 {
        let process = makeProcess(args, cwd: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                onLine(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func makeProcess(_ args: [String], cwd: URL?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        return process
    }
}

/// Runs blocking work on a GCD thread and resumes the caller with its result.
func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Mutable cell for handing a value across threads when ordering is guaranteed externally.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
