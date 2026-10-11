import Foundation

/// Surgical text edits to `project.pbxproj`. Touches only the lines it must, in Xcode's own style
/// (tab indentation, alphabetical build settings, Xcode's quoting), so diffs look hand-made.
/// Every edit is verified by re-parsing; a result that doesn't parse to the intended value throws.
enum PBXEditor {
    /// Sets `key = value;` in the `buildSettings` of each given `XCBuildConfiguration`.
    static func setBuildSetting(_ key: String, to value: String, configurations: [String], in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for id in configurations {
            try setBuildSetting(key, to: value, configuration: id, lines: &lines)
        }
        let result = lines.joined(separator: "\n")

        let objects = try PBXProjectFile.objects(in: result, path: "project.pbxproj")
        for id in configurations {
            let settings = objects[id]?["buildSettings"] as? [String: Any]
            guard settings?[key] as? String == value else { throw SochiError.editVerificationFailed("\(key) in \(id)") }
        }
        return result
    }

    private static func setBuildSetting(_ key: String, to value: String, configuration id: String, lines: inout [String]) throws {
        guard let objectLine = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\(id) ") && trimmed.hasSuffix("= {")
        }) else { throw SochiError.editVerificationFailed("configuration \(id) not found") }

        guard let open = lines[objectLine...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("buildSettings = {")
        }) else { throw SochiError.editVerificationFailed("buildSettings of \(id) not found") }

        let blockIndent = indentation(lines[open])
        let entryIndent = blockIndent + "\t"
        let entry = "\(entryIndent)\(key) = \(quote(value));"

        // `buildSettings = {};` on one line: expand it.
        if lines[open].trimmingCharacters(in: .whitespaces) == "buildSettings = {};" {
            lines.replaceSubrange(open...open, with: ["\(blockIndent)buildSettings = {", entry, "\(blockIndent)};"])
            return
        }

        var index = open + 1
        while index < lines.count {
            let line = lines[index]
            if indentation(line) == blockIndent, line.trimmingCharacters(in: .whitespaces) == "};" {
                lines.insert(entry, at: index)
                return
            }
            // Only lines at entry depth start a setting; deeper lines continue a multi-line value.
            if indentation(line) == entryIndent, let existing = settingKey(line) {
                if existing == key {
                    lines[index] = entry
                    return
                }
                if existing > key {
                    lines.insert(entry, at: index)
                    return
                }
            }
            index += 1
        }
        throw SochiError.editVerificationFailed("unterminated buildSettings in \(id)")
    }

    private static func indentation(_ line: String) -> String {
        String(line.prefix { $0 == "\t" || $0 == " " })
    }

    private static func settingKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: " = ") else { return nil }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Xcode leaves simple identifiers and paths bare and quotes everything else.
    static func quote(_ value: String) -> String {
        let bare = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$./")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(bare.contains) { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
