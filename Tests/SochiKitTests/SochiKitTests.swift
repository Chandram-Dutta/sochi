import Foundation
import Testing
@testable import SochiKit

@Suite struct BuildLogTests {
    @Test func parsesLocatedDiagnostic() {
        let event = BuildLog.parse("/tmp/App/ContentView.swift:12:9: error: cannot find 'foo' in scope")
        #expect(event == .diagnostic(Diagnostic(
            severity: .error, file: "/tmp/App/ContentView.swift", line: 12, column: 9, message: "cannot find 'foo' in scope")))
    }

    @Test func parsesBareErrors() {
        #expect(BuildLog.parse("xcodebuild: error: Unable to find a destination") ==
            .diagnostic(Diagnostic(severity: .error, message: "Unable to find a destination")))
        #expect(BuildLog.parse("error: Signing for \"App\" requires a development team.") ==
            .diagnostic(Diagnostic(severity: .error, message: "Signing for \"App\" requires a development team.")))
    }

    @Test func parsesTaskWithEscapedSpaces() {
        let line = "SwiftCompile normal arm64 /Users/me/My\\ App/Sources/Content\\ View.swift (in target 'App' from project 'App')"
        #expect(BuildLog.parse(line) == .task(kind: "SwiftCompile", subject: "Content View.swift", target: "App"))
    }

    @Test func parsesResult() {
        #expect(BuildLog.parse("** BUILD SUCCEEDED **") == .succeeded)
        #expect(BuildLog.parse("** BUILD FAILED **") == .failed)
        #expect(BuildLog.parse("    cd /tmp") == .output("    cd /tmp"))
    }
}

@Suite struct XcodebuildTests {
    let project = XcodeProject(kind: .workspace, url: URL(fileURLWithPath: "/tmp/IceCubes.xcworkspace"))

    @Test func parsesSchemesAfterWarnings() throws {
        let output = """
        2026-10-11 xcodebuild[1:2] warning: something noisy
        { "workspace": { "name": "IceCubes", "schemes": ["Pods-IceCubes", "IceCubes", "IceCubesTests"] } }
        """
        #expect(try Xcodebuild.parseSchemes(output) == ["Pods-IceCubes", "IceCubes", "IceCubesTests"])
    }

    @Test func picksAppSchemeByConvention() throws {
        #expect(try Xcodebuild.pickScheme(["Pods-IceCubes", "Models", "IceCubes"], project: project, requested: nil) == "IceCubes")
        #expect(try Xcodebuild.pickScheme(["Pods-X", "AppTests", "Other"], project: project, requested: nil) == "Other")
        #expect(try Xcodebuild.pickScheme(["IceCubes"], project: project, requested: "icecubes") == "IceCubes")
        #expect(throws: SochiError.self) { try Xcodebuild.pickScheme(["IceCubes"], project: project, requested: "Nope") }
    }

    @Test func findsAppProduct() throws {
        let output = """
        [
          { "target": "Models", "action": "build", "buildSettings": { "PRODUCT_TYPE": "com.apple.product-type.framework" } },
          { "target": "IceCubes", "action": "build", "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "TARGET_BUILD_DIR": "/dd/Build/Products/Debug-iphoneos",
              "FULL_PRODUCT_NAME": "IceCubes.app",
              "PRODUCT_BUNDLE_IDENTIFIER": "com.thomasricouard.IceCubesApp",
              "DEVELOPMENT_TEAM": "ABC123" } }
        ]
        """
        let product = try Xcodebuild.parseAppProduct(output, scheme: "IceCubes")
        #expect(product.appURL.path == "/dd/Build/Products/Debug-iphoneos/IceCubes.app")
        #expect(product.bundleIdentifier == "com.thomasricouard.IceCubesApp")
        #expect(product.developmentTeam == "ABC123")
    }
}

@Suite struct DestinationTests {
    @Test func parsesPhysicalDevicesOnly() throws {
        let json = """
        { "result": { "devices": [
          { "connectionProperties": { "tunnelState": "connected" },
            "deviceProperties": { "name": "Phone", "osVersionNumber": "27.0", "developerModeStatus": "enabled" },
            "hardwareProperties": { "udid": "0000-AAAA", "marketingName": "iPhone SE", "platform": "iOS", "reality": "physical" } },
          { "connectionProperties": { "tunnelState": "connected" },
            "deviceProperties": { "name": "iPhone 18 Pro" },
            "hardwareProperties": { "udid": "SIM-1", "platform": "iOS", "reality": "simulated" } }
        ] } }
        """
        let devices = try Devices.parse(Data(json.utf8))
        #expect(devices.map(\.udid) == ["0000-AAAA"])
        #expect(devices[0].isReachable && devices[0].developerModeEnabled)
    }

    @Test func requiresReachableDevice() throws {
        let offline = Device(udid: "1", name: "Phone", model: "iPhone SE", platform: "iOS", osVersion: "27.0",
                             tunnelState: "unavailable", developerModeEnabled: true)
        let online = Device(udid: "2", name: "iPad", model: "iPad", platform: "iOS", osVersion: "27.0",
                            tunnelState: "disconnected", developerModeEnabled: true)
        #expect(throws: SochiError.self) { try Devices.pick(from: [offline], requested: nil) }
        #expect(try Devices.pick(from: [offline, online], requested: nil) == online)
        #expect(try Devices.pick(from: [offline], requested: "phone") == offline)
        #expect(try Devices.pick(from: [offline], requested: "other") == nil)
    }

    @Test func picksSimulatorSensibly() throws {
        let json = """
        { "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [ { "udid": "old", "name": "iPhone 17 Pro", "state": "Shutdown" } ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            { "udid": "e", "name": "iPhone 17e", "state": "Shutdown" },
            { "udid": "pro", "name": "iPhone 18 Pro", "state": "Shutdown" } ]
        } }
        """
        let sims = try Simulators.parse(Data(json.utf8))
        #expect(sims.first?.runtime.description == "iOS 27.0")
        #expect(try Simulators.pick(from: sims, requested: nil).udid == "pro")
        #expect(try Simulators.pick(from: sims, requested: "old").udid == "old")
    }
}

@Suite struct SigningTests {
    let teams = [Team(id: "LZ9", name: "Adora, Corp.", isFree: false), Team(id: "DR9", name: "Me", isFree: false)]

    @Test func keepsProjectTeam() throws {
        #expect(try Signing.resolveTeam(requested: nil, projectTeam: "XYZ", available: teams) == nil)
    }

    @Test func requestedTeamWinsAndMatchesByName() throws {
        #expect(try Signing.resolveTeam(requested: "adora, corp.", projectTeam: "XYZ", available: teams) == "LZ9")
    }

    @Test func fillsGapOnlyWhenUnambiguous() throws {
        #expect(try Signing.resolveTeam(requested: nil, projectTeam: "", available: [teams[1]]) == "DR9")
        #expect(throws: SochiError.self) { try Signing.resolveTeam(requested: nil, projectTeam: "", available: teams) }
        #expect(throws: SochiError.self) { try Signing.resolveTeam(requested: nil, projectTeam: nil, available: []) }
    }

    @Test func parsesXcodeDefaults() throws {
        let plist: [String: Any] = ["IDEProvisioningTeamByIdentifier": [
            "acct": [["teamID": "LZ9", "teamName": "Adora, Corp.", "isFreeProvisioningTeam": false]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(Signing.parseTeams(data) == [teams[0]])
    }
}

@Suite struct ProjectLocatorTests {
    @Test func prefersWorkspaceAndRejectsAmbiguity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        #expect(try XcodeProject.locate(dir.path).kind == .project)

        try fm.createDirectory(at: dir.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
        #expect(try XcodeProject.locate(dir.path).kind == .workspace)

        try fm.createDirectory(at: dir.appendingPathComponent("Other.xcworkspace"), withIntermediateDirectories: true)
        #expect(throws: SochiError.self) { try XcodeProject.locate(dir.path) }
    }
}

@Suite struct CachingSafetyTests {
    let record = InstallRecord(bundleIdentifier: "dev.app", fingerprint: "abc", deviceAppURL: "file:///A/App.app/")

    @Test func skipsOnlyWhenAllEvidenceMatches() {
        #expect(record.allowsSkipping(bundleIdentifier: "dev.app", fingerprint: "abc", deviceAppURL: "file:///A/App.app/"))
        // Rebuilt with changes.
        #expect(!record.allowsSkipping(bundleIdentifier: "dev.app", fingerprint: "def", deviceAppURL: "file:///A/App.app/"))
        // Reinstalled by someone else (Xcode), or deleted from the device.
        #expect(!record.allowsSkipping(bundleIdentifier: "dev.app", fingerprint: "abc", deviceAppURL: "file:///B/App.app/"))
        #expect(!record.allowsSkipping(bundleIdentifier: "dev.app", fingerprint: "abc", deviceAppURL: nil))
        // Unsigned bundle: unknown content.
        #expect(!record.allowsSkipping(bundleIdentifier: "dev.app", fingerprint: nil, deviceAppURL: "file:///A/App.app/"))
        #expect(!record.allowsSkipping(bundleIdentifier: "other", fingerprint: "abc", deviceAppURL: "file:///A/App.app/"))
    }

    @Test func corruptOrFutureStateIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")

        var state = ProjectState()
        state.scheme = "App"
        state.installs["dev"] = record
        state.save(to: url)
        #expect(ProjectState.load(from: url) == state)

        try Data("{ not json".utf8).write(to: url)
        #expect(ProjectState.load(from: url) == ProjectState())

        try Data(#"{"version": 99, "scheme": "App", "installs": {}}"#.utf8).write(to: url)
        #expect(ProjectState.load(from: url) == ProjectState())
    }

    @Test func classifiesRecoverableFailures() {
        let scheme = Diagnostic(severity: .error, message: #"The project named "App" does not contain a scheme named "Gone". The "-list" option can be used to find the names of the schemes in the project."#)
        let team = Diagnostic(severity: .error, file: "/p/App.xcodeproj", message: #"Signing for "App" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'App' from project 'App')"#)
        #expect(BuildFailure.classify(scheme) == .missingScheme)
        #expect(BuildFailure.classify(team) == .needsTeam)
        #expect(BuildFailure.classify(Diagnostic(severity: .warning, message: team.message)) == .other)
        #expect(BuildFailure.classify(Diagnostic(severity: .error, message: "cannot find 'x' in scope")) == .other)
    }

    @Test func parsesInstalledApp() throws {
        let json = #"{"result": {"apps": [{"bundleIdentifier": "dev.app", "url": "file:///A/App.app/"}]}}"#
        #expect(try Devices.parseInstalledAppURL(Data(json.utf8), bundleID: "dev.app") == "file:///A/App.app/")
        #expect(try Devices.parseInstalledAppURL(Data(#"{"result": {"apps": []}}"#.utf8), bundleID: "dev.app") == nil)
    }

    @Test func verifiesBuiltBundleAgainstDestination() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-\(UUID().uuidString)/App.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        func writeInfo(_ info: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
        }
        let product = AppProduct(target: "App", bundleIdentifier: "dev.app", appURL: app, developmentTeam: "")
        let device = Destination.device(Device(udid: "1", name: "Phone", model: "iPhone SE", platform: "iOS",
                                               osVersion: "27.0", tunnelState: "connected", developerModeEnabled: true))

        try writeInfo(["CFBundleIdentifier": "dev.app", "DTPlatformName": "iphoneos", "CFBundleExecutable": "App"])
        try AppBundle.verify(product, for: device)
        // Unsigned: no fingerprint, so never skippable.
        try Data("binary".utf8).write(to: app.appendingPathComponent("App"))
        #expect(AppBundle.fingerprint(app) == nil)

        try writeInfo(["CFBundleIdentifier": "dev.app", "DTPlatformName": "iphonesimulator"])
        #expect(throws: SochiError.self) { try AppBundle.verify(product, for: device) }

        try writeInfo(["CFBundleIdentifier": "dev.other", "DTPlatformName": "iphoneos"])
        #expect(throws: SochiError.self) { try AppBundle.verify(product, for: device) }
    }
}

@Suite struct PBXEditorTests {
    let pbx = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tobjects = {
    \t\tC1 /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
    \t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
    \t\t\t\t\t"$(inherited)",
    \t\t\t\t\t"@executable_path/Frameworks",
    \t\t\t\t);
    \t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tC2 /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {};
    \t\t\tname = Release;
    \t\t};
    \t};
    \trootObject = C1;
    }
    """

    @Test func insertsAlphabeticallyAndExpandsEmptyBlocks() throws {
        let result = try PBXEditor.setBuildSetting("CODE_SIGN_ENTITLEMENTS", to: "App/App.entitlements", configurations: ["C1", "C2"], in: pbx)
        let lines = result.components(separatedBy: "\n")
        let debug = lines.firstIndex(of: "\t\t\t\tCODE_SIGN_ENTITLEMENTS = App/App.entitlements;")!
        #expect(lines[debug - 1].contains("ALWAYS_SEARCH_USER_PATHS"))
        #expect(lines[debug + 1].contains("LD_RUNPATH_SEARCH_PATHS"))
        #expect(result.contains("\t\t\tbuildSettings = {\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = App/App.entitlements;\n\t\t\t};\n\t\t\tname = Release;"))
        // Nothing else changed: exactly the added and expanded lines differ.
        #expect(lines.count == pbx.components(separatedBy: "\n").count + 3)
    }

    @Test func insertsAfterMultilineValuesAndReplacesExisting() throws {
        let once = try PBXEditor.setBuildSetting("MARKETING_VERSION", to: "1.0", configurations: ["C1"], in: pbx)
        #expect(once.contains("\t\t\t\t);\n\t\t\t\tMARKETING_VERSION = 1.0;\n\t\t\t\tPRODUCT_NAME"))
        let twice = try PBXEditor.setBuildSetting("MARKETING_VERSION", to: "2.0", configurations: ["C1"], in: once)
        #expect(twice.components(separatedBy: "MARKETING_VERSION").count == 2)
        #expect(twice.contains("MARKETING_VERSION = 2.0;"))
    }

    @Test func quotesLikeXcode() {
        #expect(PBXEditor.quote("App/App.entitlements") == "App/App.entitlements")
        #expect(PBXEditor.quote("My App/App.entitlements") == "\"My App/App.entitlements\"")
        #expect(PBXEditor.quote("$(SRCROOT)/App.entitlements") == "\"$(SRCROOT)/App.entitlements\"")
        #expect(PBXEditor.quote("") == "\"\"")
    }

    @Test func refusesUnknownConfiguration() {
        #expect(throws: SochiError.self) { try PBXEditor.setBuildSetting("A", to: "B", configurations: ["NOPE"], in: pbx) }
    }
}

@Suite struct CapabilityTests {
    @Test func listsUnionAndDefaultFromBundleID() throws {
        let groups = try Capabilities.named("app-group")
        #expect(try groups.entries(values: [], bundleID: "dev.app") == ["com.apple.security.application-groups": .array(["group.dev.app"])])
        let merged = Capabilities.adding(try groups.entries(values: ["group.b", "group.a"], bundleID: "x"),
                                         to: ["com.apple.security.application-groups": ["group.a"]])
        #expect(merged["com.apple.security.application-groups"] as? [String] == ["group.a", "group.b"])
        #expect(throws: SochiError.self) { try groups.entries(values: ["nogroupprefix"], bundleID: "x") }
    }

    @Test func validatesAndNormalizes() throws {
        #expect(throws: SochiError.self) { try Capabilities.named("associated-domains").entries(values: [], bundleID: "x") }
        #expect(throws: SochiError.self) { try Capabilities.named("associated-domains").entries(values: ["example.com"], bundleID: "x") }
        #expect(throws: SochiError.self) { try Capabilities.named("push").entries(values: ["extra"], bundleID: "x") }
        #expect(try Capabilities.named("keychain").entries(values: ["dev.shared"], bundleID: "x")
                == ["keychain-access-groups": .array(["$(AppIdentifierPrefix)dev.shared"])])
        #expect(throws: SochiError.self) { try Capabilities.named("teleportation") }
    }

    @Test func removesValuesOrWholeCapability() throws {
        let groups = try Capabilities.named("app-groups")
        let start: [String: Any] = ["com.apple.security.application-groups": ["group.a", "group.b"], "aps-environment": "development"]
        let partial = try Capabilities.removing(groups, values: ["group.a"], from: start)
        #expect(partial["com.apple.security.application-groups"] as? [String] == ["group.b"])
        let emptied = try Capabilities.removing(groups, values: ["group.b"], from: partial)
        #expect(emptied["com.apple.security.application-groups"] == nil)
        #expect(emptied["aps-environment"] as? String == "development")
        let health = try Capabilities.removing(try Capabilities.named("healthkit"), values: [],
            from: ["com.apple.developer.healthkit": true, "com.apple.developer.healthkit.access": [String]()])
        #expect(health.isEmpty)
    }

    @Test func detectsKnownAndUnknownKeys() {
        let (known, unknown) = Capabilities.detect(in: ["aps-environment": "development", "com.apple.developer.custom": true])
        #expect(known.map(\.0.name) == ["push"])
        #expect(unknown == ["com.apple.developer.custom"])
    }

    @Test func refusesGeneratedProjects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(ProjectEditor.generatorMarker(in: dir) == nil)
        try Data().write(to: dir.appendingPathComponent("project.yml"))
        #expect(ProjectEditor.generatorMarker(in: dir) == "project.yml")
    }

    @Test func readsTargetsFromFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj")
        let file = try PBXProjectFile(projectURL: fixture)
        let app = try #require(file.targets.first)
        #expect(app.name == "HelloApp" && app.isApplication)
        #expect(app.configurations.map(\.name) == ["Debug", "Release"])
        #expect(file.sourceFolder(of: app) == "HelloApp")
    }
}
