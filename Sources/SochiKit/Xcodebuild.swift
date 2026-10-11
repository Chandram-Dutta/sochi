import Foundation

/// The application a scheme produces, as reported by `-showBuildSettings`.
public struct AppProduct: Sendable, Equatable {
    public let target: String
    public let bundleIdentifier: String
    public let appURL: URL
    /// The project's own `DEVELOPMENT_TEAM`, empty when unset.
    public let developmentTeam: String
}

public enum Xcodebuild {
    public static func schemes(for project: XcodeProject) async throws -> [String] {
        let output = try await Shell.run(["xcodebuild", "-list", "-json"] + project.xcodebuildArguments)
        return try parseSchemes(output)
    }

    static func parseSchemes(_ output: String) throws -> [String] {
        struct Container: Decodable { let schemes: [String]? }
        struct List: Decodable { let project: Container?; let workspace: Container? }
        let list = try JSONDecoder().decode(List.self, from: jsonPayload(output, command: "xcodebuild -list"))
        return (list.workspace ?? list.project)?.schemes ?? []
    }

    /// Picks the scheme to build: the requested one, or the app scheme by convention.
    public static func pickScheme(_ schemes: [String], project: XcodeProject, requested: String?) throws -> String {
        guard !schemes.isEmpty else { throw SochiError.noSchemes(project.name) }
        if let requested {
            guard let match = schemes.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) else {
                throw SochiError.unknownScheme(requested, available: schemes)
            }
            return match
        }
        let candidates = schemes.filter { scheme in
            !scheme.hasPrefix("Pods") && !scheme.hasSuffix("Tests")
        }
        if let named = candidates.first(where: { $0 == project.name }) { return named }
        return candidates.first ?? schemes[0]
    }

    public static func appProduct(arguments: [String], scheme: String) async throws -> AppProduct {
        let output = try await Shell.run(["xcodebuild", "-showBuildSettings", "-json"] + arguments)
        return try parseAppProduct(output, scheme: scheme)
    }

    static func parseAppProduct(_ output: String, scheme: String) throws -> AppProduct {
        struct Entry: Decodable { let target: String; let buildSettings: [String: String] }
        let entries = try JSONDecoder().decode(
            [Entry].self, from: jsonPayload(output, command: "xcodebuild -showBuildSettings"))
        let apps = entries.filter { $0.buildSettings["PRODUCT_TYPE"] == "com.apple.product-type.application" }
        guard let app = apps.first(where: { $0.target == scheme }) ?? apps.first,
              let dir = app.buildSettings["TARGET_BUILD_DIR"],
              let product = app.buildSettings["FULL_PRODUCT_NAME"],
              let bundleID = app.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"]
        else { throw SochiError.noAppTarget(scheme: scheme) }
        return AppProduct(
            target: app.target,
            bundleIdentifier: bundleID,
            appURL: URL(fileURLWithPath: dir).appendingPathComponent(product),
            developmentTeam: app.buildSettings["DEVELOPMENT_TEAM"] ?? "")
    }

    /// xcodebuild sometimes prints log lines (which can contain brackets, e.g. `xcodebuild[123:456]`)
    /// before its JSON; skip to the first line that opens an object or array.
    private static func jsonPayload(_ output: String, command: String) throws -> Data {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.first == "{" || $0.first == "[" }) else {
            throw SochiError.unexpectedOutput(command: command)
        }
        return Data(lines[start...].joined(separator: "\n").utf8)
    }
}
