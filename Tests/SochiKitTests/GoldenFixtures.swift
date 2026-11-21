import Foundation
import Testing
@testable import SochiKit

enum GoldenFixtures {
    static func directory() throws -> URL? {
        let output = try Shell.runSync(["xcodebuild", "-version"], cwd: nil)
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("Xcode ") })
        let version = String(line.dropFirst("Xcode ".count)).trimmingCharacters(in: .whitespaces)
        return directory(version: version, root: GoldenTemplateTests.root.appendingPathComponent("Fixtures/Golden"))
    }

    static func directory(version: String, root: URL) -> URL? {
        let url = root.appendingPathComponent("Xcode-\(version)")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }
}

@Suite struct GoldenFixtureSelectionTests {
    @Test func selectsOnlyMatchingFixtures() {
        let root = GoldenTemplateTests.root.appendingPathComponent("Fixtures/Golden")
        #expect(GoldenFixtures.directory(version: "27.0", root: root)?.lastPathComponent == "Xcode-27.0")
        #expect(GoldenFixtures.directory(version: "26.0", root: root) == nil)
        #expect(GoldenFixtures.directory(version: "", root: root) == nil)
    }
}
