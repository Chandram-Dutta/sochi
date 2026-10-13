import Foundation

/// How a product is copied into its host app, as Xcode's build system defines it.
public struct EmbedRule: Sendable, Equatable {
    public let phaseName: String
    public let dstSubfolderSpec: String
    public let dstPath: String
}

/// Product knowledge read from the active Xcode's Swift Build specifications (`.xcspec`), so sochi never keeps
/// its own list of product types. Product types are open strings: anything Xcode defines works.
///
/// Resolution: product type (following `BasedOn`) → its own `BuildPhaseInjectionsWhenEmbedding`, or its
/// package type → the package's product file type (e.g. `wrapper.app-extension`) → that file type's injection.
public struct XcodeSpecs: Sendable {
    let productTypes: [String: [String: SpecValue]]
    let packageTypes: [String: [String: SpecValue]]
    let fileTypes: [String: [String: SpecValue]]
    /// Build settings declared as lists (`StringList`/`PathList`), which Xcode writes as arrays in the project.
    public let listSettings: Set<String>

    /// Loads specs from the Xcode that `xcode-select` points at (the same one that builds).
    public static func load() async throws -> XcodeSpecs {
        let developer = try await Shell.run(["xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let frameworks = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("SharedFrameworks")
        let roots = ["SwiftBuild.framework", "XCBuild.framework"].map { frameworks.appendingPathComponent($0) }
        return try load(from: roots)
    }

    static func load(from roots: [URL]) throws -> XcodeSpecs {
        var products: [String: [String: SpecValue]] = [:]
        var packages: [String: [String: SpecValue]] = [:]
        var files: [String: [String: SpecValue]] = [:]
        var lists = Set<String>()
        // Earlier roots win (Swift Build over the legacy XCBuild copies).
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "xcspec" {
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                else { continue }
                let entries = (plist as? [Any] ?? [plist]).compactMap(SpecValue.init)
                for case .dictionary(let entry) in entries {
                    for key in ["Options", "Properties"] {
                        guard case .array(let settings)? = entry[key] else { continue }
                        for case .dictionary(let setting) in settings {
                            if case .string(let name)? = setting["Name"], case .string(let type)? = setting["Type"],
                               type == "StringList" || type == "PathList" {
                                lists.insert(name)
                            }
                        }
                    }
                    guard case .string(let id)? = entry["Identifier"], case .string(let type)? = entry["Type"] else { continue }
                    switch type {
                    case "ProductType": if products[id] == nil { products[id] = entry }
                    case "PackageType": if packages[id] == nil { packages[id] = entry }
                    case "FileType": if files[id] == nil { files[id] = entry }
                    default: break
                    }
                }
            }
        }
        guard !products.isEmpty else { throw SochiError.xcodeDataUnavailable("build system product specifications") }
        return XcodeSpecs(productTypes: products, packageTypes: packages, fileTypes: files, listSettings: lists)
    }

    public var knownProductTypes: [String] { productTypes.keys.sorted() }

    public func isKnown(_ productType: String) -> Bool { productTypes[productType] != nil }

    /// The product's file type, e.g. `wrapper.app-extension`, used for its file reference.
    public func productFileType(_ productType: String) -> String? {
        packageType(of: productType).flatMap { package in
            guard case .dictionary(let reference)? = packageTypes[package]?["ProductReference"],
                  case .string(let fileType)? = reference["FileType"] else { return nil }
            return fileType
        }
    }

    /// The bundle suffix, e.g. `.appex`, from the package type's default `WRAPPER_SUFFIX`/`WRAPPER_EXTENSION`.
    public func wrapperSuffix(_ productType: String) -> String? {
        for id in chain(productType) {
            for key in ["WRAPPER_SUFFIX", "WRAPPER_EXTENSION"] {
                if case .dictionary(let props)? = productTypes[id]?["DefaultBuildProperties"], case .string(let v)? = props[key],
                   !v.contains("$") {
                    return v.hasPrefix(".") ? v : ".\(v)"
                }
            }
        }
        guard let package = packageType(of: productType),
              case .dictionary(let settings)? = packageTypes[package]?["DefaultBuildSettings"] else { return nil }
        for key in ["WRAPPER_SUFFIX", "WRAPPER_EXTENSION"] {
            if case .string(let v)? = settings[key], !v.contains("$") { return v.hasPrefix(".") ? v : ".\(v)" }
        }
        return nil
    }

    /// How a product of this type is embedded in its host, if Xcode embeds it at all.
    public func embedRule(_ productType: String) -> EmbedRule? {
        for id in chain(productType) {
            if let rule = Self.rule(from: productTypes[id]?["BuildPhaseInjectionsWhenEmbedding"]) { return rule }
        }
        return productFileType(productType).flatMap { Self.rule(from: fileTypes[$0]?["BuildPhaseInjectionsWhenEmbedding"]) }
    }

    /// The product type and its `BasedOn` ancestors, nearest first.
    func chain(_ productType: String) -> [String] {
        var result: [String] = []
        var current: String? = productType
        while let id = current, !result.contains(id), productTypes[id] != nil {
            result.append(id)
            if case .string(let parent)? = productTypes[id]?["BasedOn"] { current = parent } else { current = nil }
        }
        return result
    }

    private func packageType(of productType: String) -> String? {
        for id in chain(productType) {
            if case .array(let packages)? = productTypes[id]?["PackageTypes"], case .string(let first)? = packages.first {
                return first
            }
        }
        return nil
    }

    private static func rule(from value: SpecValue?) -> EmbedRule? {
        guard case .array(let injections)? = value else { return nil }
        for case .dictionary(let injection) in injections {
            guard case .string(let name)? = injection["Name"], case .string(let spec)? = injection["DstSubFolderSpec"] else { continue }
            var path = ""
            if case .string(let p)? = injection["DstPath"] { path = p }
            return EmbedRule(phaseName: name, dstSubfolderSpec: spec, dstPath: path)
        }
        return nil
    }
}

/// A Sendable mirror of an OpenStep plist value.
enum SpecValue: Sendable {
    case string(String)
    case array([SpecValue])
    case dictionary([String: SpecValue])

    init?(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber: self = .string(n.stringValue)
        case let a as [Any]: self = .array(a.compactMap(SpecValue.init))
        case let d as [String: Any]: self = .dictionary(d.compactMapValues(SpecValue.init))
        default: return nil
        }
    }
}
