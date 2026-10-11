import Foundation

/// Structural text edits to `project.pbxproj` in Xcode's layout:
/// objects live in `/* Begin <isa> section */` blocks (sections sorted by isa, objects by ID),
/// objects sit at two tabs, their keys at three, list items at four.
/// Callers must verify the result by re-parsing; this type only places text.
struct PBXTextWriter {
    var lines: [String]

    init(_ text: String) {
        lines = text.components(separatedBy: "\n")
    }

    var text: String { lines.joined(separator: "\n") }

    /// Inserts an object (its already-formatted lines) into its isa's section, creating the section if needed.
    mutating func insert(object objectLines: [String], id: String, isa: String) {
        if let begin = lines.firstIndex(of: "/* Begin \(isa) section */"),
           let end = lines[begin...].firstIndex(of: "/* End \(isa) section */") {
            let position = lines[(begin + 1)..<end].firstIndex { line in
                Self.objectID(line).map { $0 > id } ?? false
            } ?? end
            lines.insert(contentsOf: objectLines, at: position)
            return
        }
        let section = ["/* Begin \(isa) section */"] + objectLines + ["/* End \(isa) section */"]
        if let next = lines.firstIndex(where: { line in
            line.firstMatch(of: #/^/\* Begin (\w+) section \*/$/#).map { String($0.1) > isa } ?? false
        }) {
            lines.insert(contentsOf: section + [""], at: next)
        } else if let lastEnd = lines.lastIndex(where: { $0.hasPrefix("/* End ") && $0.hasSuffix(" section */") }) {
            lines.insert(contentsOf: [""] + section, at: lastEnd + 1)
        }
    }

    /// Appends `entry` (e.g. `ABC /* Name */`) to the list `key` of a multi-line object,
    /// optionally before an existing item. Creates the list if the object lacks it.
    mutating func append(_ entry: String, to key: String, ofObject id: String, before beforeID: String? = nil) throws {
        guard let start = lines.firstIndex(where: { Self.objectID($0) == id }),
              let end = lines[start...].firstIndex(of: "\t\t};")
        else { throw SochiError.editVerificationFailed("object \(id) not found") }
        let item = "\t\t\t\t\(entry),"

        if let open = lines[start..<end].firstIndex(of: "\t\t\t\(key) = ("),
           let close = lines[open..<end].firstIndex(of: "\t\t\t);") {
            let position = beforeID.flatMap { before in
                lines[(open + 1)..<close].firstIndex { $0.hasPrefix("\t\t\t\t\(before) ") || $0 == "\t\t\t\t\(before)," }
            } ?? close
            lines.insert(item, at: position)
            return
        }
        // Keys after `isa` are alphabetical; place the new list accordingly.
        let position = lines[(start + 1)..<end].firstIndex { line in
            guard line.hasPrefix("\t\t\t"), !line.hasPrefix("\t\t\t\t"), !line.hasPrefix("\t\t\tisa = "),
                  let name = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ").first
            else { return false }
            return name > key
        } ?? end
        lines.insert(contentsOf: ["\t\t\t\(key) = (", item, "\t\t\t);"], at: position)
    }

    /// The ID of a top-level object definition line (exactly two tabs of indentation), if it is one.
    private static func objectID(_ line: String) -> String? {
        guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t"), line.contains(" = {") else { return nil }
        return line.dropFirst(2).split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    /// A fresh 24-hex-digit object ID not already present in `text`.
    static func makeID(avoiding text: String) -> String {
        while true {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
            if !text.contains(id) { return id }
        }
    }
}
