import Foundation

/// The plist type and allowed values of entitlement keys, from Apple's data rather than sochi's:
/// 1. Xcode's entitlements plist schema (`DVTCorePlistStructDefs`), offline, about 100 keys;
/// 2. Apple's entitlement documentation (DocC JSON on developer.apple.com), fetched on demand and cached.
public struct EntitlementSchema: Sendable {
    public enum Kind: String, Sendable { case boolean, string, array }

    public struct Key: Sendable, Equatable {
        public let name: String
        public let kind: Kind
        public let title: String?
        public let allowedValues: [String]
    }

    let keys: [String: Key]

    public subscript(name: String) -> Key? { keys[name] }

    /// Finds a key by its display title, e.g. "Data Protection" → `com.apple.developer.default-data-protection`.
    public func key(titled title: String) -> Key? {
        keys.values.first { $0.title?.caseInsensitiveCompare(title) == .orderedSame }
    }

    // MARK: Xcode's local schema

    public static func load() async -> EntitlementSchema {
        guard let developer = try? await Shell.run(["xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return EntitlementSchema(keys: [:])
        }
        let file = URL(fileURLWithPath: developer).deletingLastPathComponent()
            .appendingPathComponent("PlugIns/DVTCorePlistStructDefs.dvtplugin/Contents/Resources/DVTCorePlistStructDefs.xcplugindata")
        return (try? load(from: file)) ?? EntitlementSchema(keys: [:])
    }

    static func load(from file: URL) throws -> EntitlementSchema {
        let data = try Data(contentsOf: file)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let xml = findXML(in: root, id: "com.apple.xcode.plist.structure-definition.entitlements")
        else { return EntitlementSchema(keys: [:]) }
        return parse(xml: xml)
    }

    private static func findXML(in value: Any, id: String) -> String? {
        if let dict = value as? [String: Any] {
            if let entry = dict[id] as? [String: Any], let xml = entry["_DVTExtensionXML"] as? String { return xml }
            for child in dict.values { if let found = findXML(in: child, id: id) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findXML(in: child, id: id) { return found } }
        }
        return nil
    }

    /// The schema is `<key name className localizedString/>` entries plus `<definition>`s for compound classes.
    static func parse(xml: String) -> EntitlementSchema {
        final class Collector: NSObject, XMLParserDelegate {
            var keyClasses: [(name: String, className: String, title: String?)] = []
            var definitions: [String: (className: String, element: String?, values: [String])] = [:]
            private var current: String?

            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                switch element {
                case "key":
                    if let name = attributes["name"], let className = attributes["className"] {
                        keyClasses.append((name, className, attributes["localizedString"]))
                    }
                case "definition":
                    if let name = attributes["name"], name != "_root_", let className = attributes["className"] {
                        definitions[name] = (className, attributes["arrayElementClassName"], [])
                        current = name
                    }
                case "value":
                    if let current, let value = attributes["name"] { definitions[current]?.values.append(value) }
                default: break
                }
            }

            func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
                if element == "definition" { current = nil }
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.parse()

        var keys: [String: Key] = [:]
        for (name, className, title) in collector.keyClasses {
            let kind: Kind
            var allowed: [String] = []
            switch className {
            case "Boolean": kind = .boolean
            case "String": kind = .string
            case "StringArray": kind = .array
            default:
                guard let definition = collector.definitions[className] else { continue }
                if definition.className == "Array" {
                    kind = .array
                    allowed = definition.element.flatMap { collector.definitions[$0]?.values } ?? []
                } else {
                    kind = definition.className == "Boolean" ? .boolean : .string
                    allowed = definition.values
                }
            }
            keys[name] = Key(name: name, kind: kind, title: title, allowedValues: allowed)
        }
        return EntitlementSchema(keys: keys)
    }

    // MARK: Apple's documentation

    /// Looks a key up in Apple's entitlement docs (DocC JSON), caching responses. Nil when offline or undocumented.
    public static func documented(_ name: String) async -> Key? {
        let cache = Paths.cacheRoot.appendingPathComponent("entitlement-docs/\(name).json")
        var data = try? Data(contentsOf: cache)
        if data == nil, let url = URL(string: "https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/\(name).json") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let (fetched, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                data = fetched
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fetched.write(to: cache, options: .atomic)
            }
        }
        return data.flatMap { parseDocs($0, name: name) }
    }

    static func parseDocs(_ data: Data, name: String) -> Key? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["primaryContentSections"] as? [[String: Any]] else { return nil }
        var kind: Kind?
        var title: String?
        var allowed: [String] = []
        for section in sections {
            if let details = section["details"] as? [String: Any] {
                title = details["ideTitle"] as? String
                if let value = (details["value"] as? [[String: Any]])?.first {
                    let base = (value["baseType"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                    kind = (value["arrayMode"] as? Bool ?? false) ? .array : (base == "boolean" ? .boolean : .string)
                }
            }
            if section["kind"] as? String == "possibleValues" {
                allowed = (section["values"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            }
        }
        return kind.map { Key(name: name, kind: $0, title: title, allowedValues: allowed) }
    }
}
