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
    /// Rules that turn Apple's catalog into entitlements, checked against the installed Xcode's data.
    @Test func writesEntitlementsFromAppleData() async throws {
        let catalog = try await CapabilityCatalog.load(team: nil)
        let schema = await EntitlementSchema.load()
        func entries(_ name: String, _ values: [String] = []) async throws -> [String: PlistValue] {
            try await CapabilityWriter.entries(
                for: try CapabilityWriter.resolve(name, catalog: catalog), values: values, bundleID: "dev.app", schema: schema)
        }
        #expect(try await entries("push-notifications") == ["aps-environment": .string("development")])
        // "push" is ambiguous in Apple's catalog (Push to Talk, Location Push…), so sochi asks rather than guesses.
        #expect(throws: SochiError.self) { try CapabilityWriter.resolve("push", catalog: catalog) }
        #expect(try await entries("sign-in-with-apple") == ["com.apple.developer.applesignin": .array(["Default"])])
        // Only the required key: the optional clinical-records list and background delivery are opt-in.
        #expect(try await entries("healthkit") == ["com.apple.developer.healthkit": .bool(true)])
        #expect(try await entries("game-center") == ["com.apple.developer.game-center": .bool(true)])
        // Associated Domains is an array per Xcode's schema, though the portal catalog calls it a STRING wildcard.
        #expect(try await entries("associated-domains", ["applinks:example.com"])
                == ["com.apple.developer.associated-domains": .array(["applinks:example.com"])])
        await #expect(throws: SochiError.self) { try await entries("associated-domains") }
        await #expect(throws: SochiError.self) { try await entries("network-extensions") }
        #expect(try await entries("network-extensions", ["packet-tunnel-provider"])
                == ["com.apple.developer.networking.networkextension": .array(["packet-tunnel-provider"])])
        await #expect(throws: SochiError.self) { try await entries("network-extensions", ["teleport"]) }
        // No catalog entitlements: found in Xcode's schema by name, values from the schema/docs.
        await #expect(throws: SochiError.self) { try await entries("data-protection") }
        #expect(try await entries("data-protection", ["NSFileProtectionComplete"])
                == ["com.apple.developer.default-data-protection": .string("NSFileProtectionComplete")])
        await #expect(throws: SochiError.self) { try await entries("in-app-purchase") }
        await #expect(throws: SochiError.self) { try await entries("push-notifications", ["extra"]) }
    }

    @Test func handlesXcodeOnlyCapabilities() async throws {
        let catalog = try await CapabilityCatalog.load(team: nil)
        let schema = EntitlementSchema(keys: [:])
        let keychain = try CapabilityWriter.resolve("keychain-sharing", catalog: catalog)
        #expect(try await CapabilityWriter.entries(for: keychain, values: [], bundleID: "dev.app", schema: schema)
                == ["keychain-access-groups": .array(["$(AppIdentifierPrefix)dev.app"])])
        #expect(try await CapabilityWriter.entries(for: keychain, values: ["dev.shared"], bundleID: "x", schema: schema)
                == ["keychain-access-groups": .array(["$(AppIdentifierPrefix)dev.shared"])])
        let modes = try CapabilityWriter.resolve("background-modes", catalog: catalog)
        await #expect(throws: SochiError.self) { try await CapabilityWriter.entries(for: modes, values: [], bundleID: "x", schema: schema) }
    }

    @Test func mergesAndRemovesValues() {
        let groups = "com.apple.security.application-groups"
        let merged = CapabilityWriter.adding([groups: .array(["group.b", "group.a"])], to: [groups: ["group.a"]])
        #expect(merged[groups] as? [String] == ["group.a", "group.b"])
        let start: [String: Any] = [groups: ["group.a", "group.b"], "aps-environment": "development"]
        let partial = CapabilityWriter.removing(keys: [groups], values: ["group.a"], from: start)
        #expect(partial[groups] as? [String] == ["group.b"])
        let emptied = CapabilityWriter.removing(keys: [groups], values: ["group.b"], from: partial)
        #expect(emptied[groups] == nil && emptied["aps-environment"] as? String == "development")
        #expect(CapabilityWriter.removing(keys: ["aps-environment"], values: [], from: start)["aps-environment"] == nil)
    }

    @Test func readsXcodeSchemaAndDocs() throws {
        let xml = #"<extension><definition name="_root_" className="Dictionary"><dictionaryKeys><key name="a.flag" className="Boolean" localizedString="Flag"/><key name="a.list" className="ListClass" localizedString="List"/></dictionaryKeys></definition><definition name="ListClass" className="Array" arrayElementClassName="ItemClass"/><definition name="ItemClass" className="String"><allowableValues><value name="one"/><value name="two"/></allowableValues></definition></extension>"#
        let schema = EntitlementSchema.parse(xml: xml)
        #expect(schema["a.flag"]?.kind == .boolean)
        #expect(schema["a.list"] == .init(name: "a.list", kind: .array, title: "List", allowedValues: ["one", "two"]))
        #expect(schema.key(titled: "list")?.name == "a.list")
        let docs = #"{"primaryContentSections":[{"kind":"details","details":{"ideTitle":"Domains","value":[{"arrayMode":true,"baseType":"string "}]}},{"kind":"possibleValues","values":[{"name":"x"}]}]}"#
        #expect(EntitlementSchema.parseDocs(Data(docs.utf8), name: "k") == .init(name: "k", kind: .array, title: "Domains", allowedValues: ["x"]))
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

/// Reads the installed Xcode's build specs: these assert sochi derives embedding from Apple's data, not a list.
@Suite struct XcodeSpecsTests {
    @Test func resolvesEmbeddingFromInstalledXcode() async throws {
        let specs = try await XcodeSpecs.load()
        let foundation = EmbedRule(phaseName: "Embed Foundation Extensions", dstSubfolderSpec: "13", dstPath: "")
        #expect(specs.embedRule("com.apple.product-type.app-extension") == foundation)
        #expect(specs.productFileType("com.apple.product-type.app-extension") == "wrapper.app-extension")
        #expect(specs.wrapperSuffix("com.apple.product-type.app-extension") == ".appex")
        // Subtypes inherit through BasedOn.
        #expect(specs.embedRule("com.apple.product-type.app-extension.messages") == foundation)
        #expect(specs.embedRule("com.apple.product-type.extensionkit-extension")
                == EmbedRule(phaseName: "Embed ExtensionKit Extensions", dstSubfolderSpec: "16", dstPath: "$(EXTENSIONS_FOLDER_PATH)"))
        #expect(specs.embedRule("com.apple.product-type.application.on-demand-install-capable")
                == EmbedRule(phaseName: "Embed App Clips", dstSubfolderSpec: "16", dstPath: "$(CONTENTS_FOLDER_PATH)/AppClips"))
        #expect(specs.productFileType("com.apple.product-type.application.on-demand-install-capable") == "wrapper.application")
        #expect(!specs.isKnown("com.apple.product-type.teleporter"))
        // Apps aren't embedded (App Clips are, via their own product type).
        #expect(specs.embedRule("com.apple.product-type.application") == nil)
        #expect(specs.wrapperSuffix("com.apple.product-type.application") == ".app")
        #expect(specs.wrapperSuffix("com.apple.product-type.extensionkit-extension") == ".appex")
    }
}

/// Compares targets rendered by sochi with targets Xcode 27 created itself (Fixtures/Golden/Xcode-27.0).
/// Template-specific content (sources, settings) is out of scope here; this checks the wiring.
@Suite struct GoldenTargetTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Wiring: Equatable, CustomStringConvertible {
        var productType: String
        var productFileType: String
        var productSuffix: String
        var embedPhase: String
        var embedSpec: String
        var embedPath: String
        var excludesInfoPlist: Bool
        var hostDependsOnIt: Bool
        var hasTargetAttributes: Bool
        var folderBeforeProducts: Bool
        var description: String { "\(productType) \(productFileType) *\(productSuffix) [\(embedPhase) \(embedSpec) \(embedPath)] plist-excluded:\(excludesInfoPlist) dep:\(hostDependsOnIt) attrs:\(hasTargetAttributes) order:\(folderBeforeProducts)" }
    }

    static func wiring(of name: String, in text: String) throws -> Wiring {
        let objects = try PBXProjectFile.objects(in: text, path: name)
        let (rootID, root) = objects.first { $0.value["isa"] as? String == "PBXProject" }!
        let (targetID, target) = objects.first { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == name }!
        let host = objects.first { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == "HelloApp" }!.value
        let productID = target["productReference"] as! String
        let product = objects[productID]!
        let phase = (host["buildPhases"] as! [String]).compactMap { objects[$0] }.first { phase in
            (phase["files"] as? [String] ?? []).contains { objects[$0]?["fileRef"] as? String == productID }
        }
        let group = objects[(target["fileSystemSynchronizedGroups"] as! [String])[0]]!
        let exceptions = (group["exceptions"] as? [String] ?? []).compactMap { objects[$0]?["membershipExceptions"] as? [String] }.flatMap { $0 }
        let mainChildren = objects[root["mainGroup"] as! String]!["children"] as! [String]
        let groupID = target["fileSystemSynchronizedGroups"] as! [String]
        let attributes = ((root["attributes"] as? [String: Any])?["TargetAttributes"] as? [String: Any]) ?? [:]
        let path = product["path"] as! String
        return Wiring(
            productType: target["productType"] as! String,
            productFileType: product["explicitFileType"] as! String,
            productSuffix: String(path[path.lastIndex(of: ".")!...]),
            embedPhase: phase?["name"] as? String ?? "-",
            embedSpec: phase?["dstSubfolderSpec"] as? String ?? "-",
            embedPath: phase?["dstPath"] as? String ?? "-",
            excludesInfoPlist: exceptions.contains("Info.plist"),
            hostDependsOnIt: (host["dependencies"] as! [String]).contains { objects[$0]?["target"] as? String == targetID },
            hasTargetAttributes: attributes[targetID] != nil,
            folderBeforeProducts: mainChildren.firstIndex(of: groupID[0])! < mainChildren.firstIndex(of: root["productRefGroup"] as! String)!)
        _ = rootID
    }

    @Test(arguments: [
        ("NotificationService", "com.apple.product-type.app-extension"),
        ("Share", "com.apple.product-type.app-extension"),
        ("AppIntents", "com.apple.product-type.extensionkit-extension"),
        ("AppClip", "com.apple.product-type.application.on-demand-install-capable"),
    ])
    func wiringMatchesXcode(name: String, productType: String) async throws {
        let golden = try String(contentsOf: Self.root.appendingPathComponent(
            "Fixtures/Golden/Xcode-27.0/AllTemplates/HelloApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        let projectURL = Self.root.appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj")
        let file = try PBXProjectFile(projectURL: projectURL)
        var spec = TargetSpec(name: name, folder: name, productType: productType)
        spec.infoPlist = Data("<plist/>".utf8)
        let output = try TargetBuilder.render(spec, in: file, host: file.targets[0], specs: try await XcodeSpecs.load(), toolsVersion: "27.0")

        let ours = try Self.wiring(of: name, in: output.text)
        let xcodes = try Self.wiring(of: name, in: golden)
        #expect(ours == xcodes, "sochi: \(ours)\nxcode: \(xcodes)")
    }

    @Test func explicitFrameworksAreGroupedLikeXcode() async throws {
        let file = try PBXProjectFile(projectURL: Self.root.appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj"))
        var spec = TargetSpec(name: "Widget", folder: "Widget", productType: "com.apple.product-type.app-extension")
        spec.frameworks = ["WidgetKit", "SwiftUI"]
        let text = try TargetBuilder.render(spec, in: file, host: file.targets[0], specs: try await XcodeSpecs.load(), toolsVersion: "27.0").text
        let objects = try PBXProjectFile.objects(in: text, path: "x")
        let group = try #require(objects.values.first { $0["isa"] as? String == "PBXGroup" && $0["name"] as? String == "Frameworks" })
        let names = (group["children"] as! [String]).compactMap { objects[$0]?["name"] as? String }
        #expect(names == ["WidgetKit.framework", "SwiftUI.framework"])
        let main = objects.values.first { $0["isa"] as? String == "PBXGroup" && $0["children"] != nil && $0["name"] == nil && $0["path"] == nil }!
        let order = (main["children"] as! [String]).map { objects[$0]?["path"] as? String ?? objects[$0]?["name"] as? String ?? "?" }
        #expect(order == ["HelloApp", "Widget", "Frameworks", "Products"])
    }
}

/// Reads the installed Xcode's capability catalog: sochi derives capabilities from Apple's data.
@Suite struct CapabilityCatalogTests {
    @Test func loadsAndQueriesTheInstalledCatalog() async throws {
        let catalog = try await CapabilityCatalog.load(team: nil)
        let ios = catalog.available()
        #expect(ios.count > 80)
        let push = try catalog.find("push-notifications")
        #expect(push.id == "PUSH_NOTIFICATIONS")
        #expect(push.entitlements(for: "IOS").map(\.key) == ["aps-environment"])
        #expect(try catalog.find("PUSH_NOTIFICATIONS").id == push.id)
        #expect(try catalog.find("Sign In with Apple").slug == "sign-in-with-apple")
        #expect(try catalog.find("healthkit").id == "HEALTHKIT")
        #expect(throws: SochiError.self) { try catalog.find("teleportation") }
        let groups = try catalog.find("app-groups")
        #expect(groups.entitlements(for: "IOS").first?.values.first?.isPlaceholder == true)

        let (enabled, unclaimed) = catalog.detect(in: ["aps-environment": "development", "com.example.custom": true])
        #expect(enabled.map(\.id).contains("PUSH_NOTIFICATIONS"))
        #expect(unclaimed == ["com.example.custom"])
    }
}
