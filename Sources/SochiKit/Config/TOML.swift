import Foundation

/// The TOML subset sochi.toml needs: tables (`[a.b]`), key/values with bare or quoted keys, basic and literal
/// strings, integers, booleans, arrays (multi-line too) and inline tables, plus comments. Anything else (multi-line
/// strings, dates, floats, arrays of tables) is reported as an error rather than misread.
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([TOMLValue])
    case table([(key: String, value: TOMLValue)])

    public static func == (lhs: TOMLValue, rhs: TOMLValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.integer(a), .integer(b)): a == b
        case let (.boolean(a), .boolean(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.table(a), .table(b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public subscript(key: String) -> TOMLValue? {
        if case .table(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }
    public var pairs: [(key: String, value: TOMLValue)]? { if case .table(let p) = self { return p }; return nil }
}

public enum TOML {
    public struct ParseError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "sochi.toml line \(line): \(message)" }
    }

    /// Parses a document into a root table (tables keep their source order).
    public static func parse(_ text: String) throws -> TOMLValue {
        var root: [(key: String, value: TOMLValue)] = []
        var currentPath: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let lineNumber = index + 1
            var line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[[") { throw ParseError(line: lineNumber, message: "arrays of tables aren't supported") }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError(line: lineNumber, message: "unterminated table header") }
                var scanner = Scanner(Array(line.dropFirst().dropLast()))
                currentPath = try scanner.keyPath(line: lineNumber)
                try insert(.table([]), at: currentPath, into: &root, replaceTables: false, line: lineNumber)
                continue
            }
            // Multi-line arrays/inline tables: keep reading until brackets balance outside strings.
            while !balanced(line), index < lines.count {
                line += " " + stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
                index += 1
            }
            var scanner = Scanner(Array(line))
            let keyPath = try scanner.keyPath(line: lineNumber, terminator: "=")
            guard scanner.consume("=") else { throw ParseError(line: lineNumber, message: "expected '='") }
            let value = try scanner.value(line: lineNumber)
            scanner.skipSpaces()
            guard scanner.atEnd else { throw ParseError(line: lineNumber, message: "unexpected text after value") }
            try insert(value, at: currentPath + keyPath, into: &root, replaceTables: true, line: lineNumber)
        }
        return .table(root)
    }

    /// Formats a value the way sochi writes it (strings quoted, arrays and tables inline).
    public static func format(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .integer(let i): return String(i)
        case .boolean(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map(format).joined(separator: ", ") + "]"
        case .table(let pairs): return pairs.isEmpty ? "{}" : "{ " + pairs.map { "\(formatKey($0.key)) = \(format($0.value))" }.joined(separator: ", ") + " }"
        }
    }

    public static func formatKey(_ key: String) -> String {
        let bare = key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return bare && !key.isEmpty ? key : quote(key)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    // MARK: Helpers

    static func stripComment(_ line: String) -> String {
        var inBasic = false, inLiteral = false, escaped = false
        for (offset, character) in line.enumerated() {
            if escaped { escaped = false; continue }
            if inBasic, character == "\\" { escaped = true; continue }
            if character == "\"", !inLiteral { inBasic.toggle() }
            else if character == "'", !inBasic { inLiteral.toggle() }
            else if character == "#", !inBasic, !inLiteral { return String(line.prefix(offset)) }
        }
        return line
    }

    static func balanced(_ line: String) -> Bool {
        var depth = 0, inBasic = false, inLiteral = false, escaped = false
        for character in line {
            if escaped { escaped = false; continue }
            if inBasic, character == "\\" { escaped = true; continue }
            if character == "\"", !inLiteral { inBasic.toggle(); continue }
            if character == "'", !inBasic { inLiteral.toggle(); continue }
            guard !inBasic, !inLiteral else { continue }
            if character == "[" || character == "{" { depth += 1 }
            if character == "]" || character == "}" { depth -= 1 }
        }
        return depth <= 0
    }

    static func insert(_ value: TOMLValue, at path: [String], into table: inout [(key: String, value: TOMLValue)],
                       replaceTables: Bool, line: Int) throws {
        guard let first = path.first else { return }
        if path.count == 1 {
            if let existing = table.firstIndex(where: { $0.key == first }) {
                if case .table = table[existing].value, case .table = value, !replaceTables { return }
                throw ParseError(line: line, message: "duplicate key '\(first)'")
            }
            table.append((first, value))
            return
        }
        var child: [(key: String, value: TOMLValue)] = []
        if let existing = table.firstIndex(where: { $0.key == first }) {
            guard case .table(let pairs) = table[existing].value else { throw ParseError(line: line, message: "'\(first)' isn't a table") }
            child = pairs
            try insert(value, at: Array(path.dropFirst()), into: &child, replaceTables: replaceTables, line: line)
            table[existing].value = .table(child)
        } else {
            try insert(value, at: Array(path.dropFirst()), into: &child, replaceTables: replaceTables, line: line)
            table.append((first, .table(child)))
        }
    }

    struct Scanner {
        let chars: [Character]
        var position = 0
        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { position >= chars.count }
        var peek: Character? { atEnd ? nil : chars[position] }

        mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { position += 1 } }

        mutating func consume(_ character: Character) -> Bool {
            skipSpaces()
            guard peek == character else { return false }
            position += 1
            return true
        }

        mutating func keyPath(line: Int, terminator: Character? = nil) throws -> [String] {
            var path: [String] = []
            repeat {
                skipSpaces()
                if peek == "\"" { path.append(try basicString(line: line)) }
                else if peek == "'" { path.append(try literalString(line: line)) }
                else {
                    var key = ""
                    while let c = peek, c.isLetter || c.isNumber || c == "-" || c == "_" { key.append(c); position += 1 }
                    guard !key.isEmpty else { throw ParseError(line: line, message: "expected a key") }
                    path.append(key)
                }
                skipSpaces()
            } while consume(".")
            return path
        }

        mutating func value(line: Int) throws -> TOMLValue {
            skipSpaces()
            switch peek {
            case "\"":
                if chars.count >= position + 3, String(chars[position..<position + 3]) == "\"\"\"" {
                    throw ParseError(line: line, message: "multi-line strings aren't supported")
                }
                return .string(try basicString(line: line))
            case "'": return .string(try literalString(line: line))
            case "[":
                position += 1
                var items: [TOMLValue] = []
                while true {
                    skipSpaces()
                    if consume("]") { return .array(items) }
                    items.append(try value(line: line))
                    if consume(",") { continue }
                    guard consume("]") else { throw ParseError(line: line, message: "expected ',' or ']'") }
                    return .array(items)
                }
            case "{":
                position += 1
                var pairs: [(key: String, value: TOMLValue)] = []
                skipSpaces()
                if consume("}") { return .table(pairs) }
                while true {
                    let path = try keyPath(line: line)
                    guard consume("=") else { throw ParseError(line: line, message: "expected '=' in inline table") }
                    try TOML.insert(try value(line: line), at: path, into: &pairs, replaceTables: true, line: line)
                    if consume(",") { continue }
                    guard consume("}") else { throw ParseError(line: line, message: "expected ',' or '}'") }
                    return .table(pairs)
                }
            default:
                var word = ""
                while let c = peek, !" \t,]}".contains(c) { word.append(c); position += 1 }
                if word == "true" { return .boolean(true) }
                if word == "false" { return .boolean(false) }
                if let int = Int(word.replacingOccurrences(of: "_", with: "")) { return .integer(int) }
                throw ParseError(line: line, message: "unsupported value '\(word)' (quote strings)")
            }
        }

        mutating func basicString(line: Int) throws -> String {
            position += 1
            var result = ""
            while let c = peek {
                position += 1
                if c == "\"" { return result }
                if c == "\\" {
                    guard let e = peek else { break }
                    position += 1
                    switch e {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "u", "U":
                        let length = e == "u" ? 4 : 8
                        guard position + length <= chars.count, let code = UInt32(String(chars[position..<position + length]), radix: 16),
                              let scalar = Unicode.Scalar(code) else { throw ParseError(line: line, message: "bad unicode escape") }
                        result.unicodeScalars.append(scalar)
                        position += length
                    default: throw ParseError(line: line, message: "bad escape '\\\(e)'")
                    }
                } else {
                    result.append(c)
                }
            }
            throw ParseError(line: line, message: "unterminated string")
        }

        mutating func literalString(line: Int) throws -> String {
            position += 1
            var result = ""
            while let c = peek {
                position += 1
                if c == "'" { return result }
                result.append(c)
            }
            throw ParseError(line: line, message: "unterminated string")
        }
    }
}
