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
        #expect(devices[0].isReachable && devices[0].developerModeEnabled == true)
    }

    /// A device CoreDevice hasn't connected to yet (just plugged in) has no reality, marketing name or developer mode
    /// status; it's still a usable physical device. Shape taken from an iPad on Xcode 27.0.
    @Test func keepsDevicesCoreDeviceHasNotConnectedTo() throws {
        let json = """
        { "result": { "devices": [
          { "connectionProperties": { "pairingState": "paired", "transportType": "wired", "tunnelState": "disconnected" },
            "deviceProperties": { "bootState": "booted", "name": "iPad", "osVersionNumber": "27.2" },
            "hardwareProperties": { "deviceType": "iPad", "platform": "iOS", "productType": "iPad12,2", "udid": "0000-BBBB" } }
        ] } }
        """
        let devices = try Devices.parse(Data(json.utf8))
        #expect(devices.map(\.udid) == ["0000-BBBB"])
        #expect(devices[0].model == "iPad" && devices[0].developerModeEnabled == nil)
        #expect(devices[0].isReachable && devices[0].status == "available")
    }

    @Test func picksDeviceByAnyUnambiguousPart() throws {
        func device(_ udid: String, _ name: String, _ model: String) -> Device {
            Device(udid: udid, name: name, model: model, platform: "iOS", osVersion: "27.0",
                   tunnelState: "disconnected", developerModeEnabled: true)
        }
        let se = device("00008030-001519A4", "Chandram’s iPhone", "iPhone SE")
        let pro = device("00008140-00AA22BB", "Chandram’s iPhone", "iPhone 18 Pro")
        let pad = device("00008030-00087959", "Chandram’s iPad", "iPad (9th generation)")
        let all = [se, pro, pad]

        #expect(try Devices.pick(from: all, requested: "ipad") == pad)              // part of the name
        #expect(try Devices.pick(from: all, requested: "chandram's ipad") == pad)   // typed ' for ’
        #expect(try Devices.pick(from: all, requested: "se") == se)                 // part of the model
        #expect(try Devices.pick(from: all, requested: "18 pro") == pro)
        #expect(try Devices.pick(from: all, requested: "00008140") == pro)          // start of the UDID
        #expect(try Devices.pick(from: all, requested: "00008030-00087959") == pad)
        #expect(try Devices.pick(from: all, requested: "watch") == nil)
        // Same name on two phones, or a prefix both share: list them instead of guessing.
        #expect(throws: SochiError.self) { try Devices.pick(from: all, requested: "chandram’s iphone") }
        #expect(throws: SochiError.self) { try Devices.pick(from: all, requested: "00008030") }
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
        // Apps aren't embedded (App Clips are, via their own product type)…
        #expect(specs.embedRule("com.apple.product-type.application") == nil)
        // …except watchOS apps inside their iOS companion, via the watchOS platform's spec.
        #expect(specs.embedRule("com.apple.product-type.application", platform: "watchos")
                == EmbedRule(phaseName: "Embed Watch Content", dstSubfolderSpec: "16", dstPath: "$(CONTENTS_FOLDER_PATH)/Watch"))
        #expect(specs.wrapperSuffix("com.apple.product-type.application") == ".app")
        #expect(specs.wrapperSuffix("com.apple.product-type.extensionkit-extension") == ".appex")
        // List-typed settings, which Xcode writes as arrays.
        #expect(specs.listSettings.isSuperset(of: ["LD_RUNPATH_SEARCH_PATHS", "GCC_PREPROCESSOR_DEFINITIONS", "OTHER_LDFLAGS"]))
        #expect(!specs.listSettings.contains("PRODUCT_NAME"))
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

/// Runs Xcode's own templates through sochi's engine and compares with what Xcode 27 produced itself
/// (Fixtures/Golden/Xcode-27.0/AllTemplates, made with each template's defaults).
@Suite struct GoldenTemplateTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Not template content: sochi takes these from the host app (the signing style comes from Xcode's signing UI).
    static let hostAligned: Set<String> = ["SWIFT_VERSION", "IPHONEOS_DEPLOYMENT_TARGET", "CODE_SIGN_STYLE"]

    @Test(arguments: [
        ("Widget Extension", "Widget", "WidgetExtension"),
        ("Share Extension", "Share", "Share"),
        ("Notification Service Extension", "NotificationService", "NotificationService"),
        ("App Intents Extension", "AppIntents", "AppIntents"),
        ("App Clip", "AppClip", "AppClip"),
    ])
    func matchesXcode(template: String, name: String, targetName: String) async throws {
        let index = try await TemplateIndex.load()
        let file = try PBXProjectFile(projectURL: Self.root.appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj"))
        let context = TemplateContext(
            name: name, projectName: "HelloApp", hostBundleIdentifier: "dev.sochi.HelloApp", hostProductName: "HelloApp",
            hostProductType: "com.apple.product-type.application", developmentTeam: nil, fullUserName: "Someone")
        let outputs = try TemplateEngine(index: index, specs: try await XcodeSpecs.load()).instantiate(
            try index.find(template), context: context, projectSettings: file.projectBuildSettings, configurations: ["Debug", "Release"])
        #expect(outputs.count == 1)
        let output = try #require(outputs.first)
        #expect(output.targetName == targetName)

        // Files, byte for byte apart from the "Created by" line.
        let goldenDir = Self.root.appendingPathComponent("Fixtures/Golden/Xcode-27.0/AllTemplates/\(name)")
        var golden: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: goldenDir, includingPropertiesForKeys: [.isDirectoryKey])!
        while let url = walker.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true, url.lastPathComponent != "Info.plist" else { continue }
            golden[url.path.replacingOccurrences(of: goldenDir.path + "/", with: "")] = try Data(contentsOf: url)
        }
        #expect(Set(output.files.keys) == Set(golden.keys))
        func normalized(_ data: Data?) -> String {
            (data.flatMap { String(data: $0, encoding: .utf8) } ?? "<binary>").replacing(#/Created by .* on .*\./#, with: "Created by X on D.")
        }
        for (path, data) in golden {
            #expect(normalized(output.files[path]) == normalized(data), "\(path) differs")
        }

        // Info.plist.
        let goldenInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: goldenDir.appendingPathComponent("Info.plist")), format: nil) as! NSDictionary
        let ours = try PropertyListSerialization.propertyList(from: try #require(output.infoPlist), format: nil) as! NSDictionary
        #expect(ours == goldenInfo)

        // Build settings per configuration.
        let objects = try PBXProjectFile.objects(
            in: String(contentsOf: Self.root.appendingPathComponent("Fixtures/Golden/Xcode-27.0/AllTemplates/HelloApp.xcodeproj/project.pbxproj"), encoding: .utf8), path: "g")
        let target = objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == targetName }!
        for configID in objects[target["buildConfigurationList"] as! String]!["buildConfigurations"] as! [String] {
            let config = objects[configID]!
            let name = config["name"] as! String
            let expected = (config["buildSettings"] as! [String: Any]).filter { !Self.hostAligned.contains($0.key) }
            let actual = (output.settings[name] ?? [:]).filter { !Self.hostAligned.contains($0.key) }.mapValues { setting -> Any in
                switch setting { case .string(let s): s; case .list(let l): l }
            }
            let missing = Set(expected.keys).subtracting(actual.keys).sorted()
            let extra = Set(actual.keys).subtracting(expected.keys).sorted()
            let different = expected.keys.filter { key in actual[key].map { !NSDictionary(dictionary: [key: $0]).isEqual(to: [key: expected[key]!]) } ?? false }.sorted()
            #expect(missing.isEmpty && extra.isEmpty && different.isEmpty,
                    "\(targetName) \(name): missing \(missing) extra \(extra) different \(different.map { "\($0): ours \(actual[$0]!) xcode \(expected[$0]!)" })")
        }
        let frameworks = (target["buildPhases"] as! [String]).compactMap { objects[$0] }.first { $0["isa"] as? String == "PBXFrameworksBuildPhase" }!
        let linked = (frameworks["files"] as! [String]).compactMap { objects[objects[$0]!["fileRef"] as! String]?["name"] as? String }
        #expect(Set(output.frameworks.map { "\($0).framework" }) == Set(linked))
    }
}

/// Group → synchronized folder migration: conversions must be faithful, and anything else must stay a group.
@Suite struct MigrationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Copies the classic fixture so tests can add files on disk or tweak the project.
    func classicCopy(edit: (inout String) -> Void = { _ in }, extraFiles: [String: String] = [:]) throws -> PBXProjectFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-migrate-test-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent("Fixtures/Classic"), to: dir)
        for (path, contents) in extraFiles {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let pbxproj = dir.appendingPathComponent("Classic.xcodeproj/project.pbxproj")
        var text = try String(contentsOf: pbxproj, encoding: .utf8)
        edit(&text)
        try text.write(to: pbxproj, atomically: true, encoding: .utf8)
        return try PBXProjectFile(projectURL: dir.appendingPathComponent("Classic.xcodeproj"))
    }

    @Test func convertsTheClassicFixtureFaithfully() throws {
        let (plan, report) = try Migration.plan(try classicCopy(), wrapperExtensions: ["xcassets"])
        #expect(report.converted.map(\.folder).sorted() == ["ClassicApp", "ClassicKit", "Shared"])
        let app = try #require(report.converted.first { $0.folder == "ClassicApp" })
        #expect(app.exceptions["ClassicApp"] == ["ClassicApp-Bridging-Header.h", "Excluded.swift", "Info.plist", "README.md"])
        #expect(app.flags["ClassicApp"] == ["util.c": "-DCLASSIC=1"])
        #expect(report.converted.first { $0.folder == "Shared" }?.targets == ["ClassicApp", "ClassicKit"])
        #expect(report.skipped.map(\.group) == ["Docs"])

        let text = String(decoding: plan.edits[0].updated, as: UTF8.self)
        let objects = try PBXProjectFile.objects(in: text, path: "x")
        #expect(text.contains("objectVersion = 77;"))
        #expect(!objects.values.contains { $0["isa"] as? String == "PBXBuildFile" })
        #expect(objects.values.filter { $0["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" }.count == 3)
        // Docs (virtual) and Notes.md survive; the Products group is untouched.
        #expect(objects.values.contains { $0["path"] as? String == "Notes.md" })
        #expect(objects.values.contains { $0["path"] as? String == "ClassicApp.app" })
    }

    @Test func picksUpFilesAddedOnDiskAsExceptions() throws {
        let (_, report) = try Migration.plan(
            try classicCopy(extraFiles: ["ClassicApp/Resources/Stray.swift": "#error(\"no\")", "ClassicApp/.hidden": "x"]),
            wrapperExtensions: ["xcassets"])
        let app = try #require(report.converted.first { $0.folder == "ClassicApp" })
        #expect(app.exceptions["ClassicApp"]?.contains("Resources/Stray.swift") == true)
        #expect(app.exceptions["ClassicApp"]?.contains(".hidden") == false)
    }

    @Test(arguments: [
        // A per-file attribute the folder format can't carry.
        ("COMPILER_FLAGS = \"-DCLASSIC=1\";", "ATTRIBUTES = (Weak, );", "per-file ATTRIBUTES"),
        // A referenced file that's gone from disk.
        ("path = data.json;", "path = missing.json;", "missing on disk"),
        // A folder reference ("blue folder").
        ("lastKnownFileType = text.json; path = data.json;", "lastKnownFileType = folder; path = data.json;", "folder reference"),
    ])
    func leavesUnconvertibleGroupsAlone(find: String, replace: String, reason: String) throws {
        let file = try classicCopy { $0 = $0.replacingOccurrences(of: find, with: replace) }
        let (_, report) = try Migration.plan(file, wrapperExtensions: ["xcassets"])
        #expect(!report.converted.contains { $0.folder == "ClassicApp" })
        let skipped = try #require(report.skipped.first { $0.group == "ClassicApp" || $0.group == "Resources" })
        #expect(skipped.reason.contains(reason) || reason == "per-file ATTRIBUTES" && skipped.reason.contains("ATTRIBUTES"), "\(skipped.reason)")
        // Unaffected folders still convert.
        #expect(report.converted.contains { $0.folder == "Shared" })
    }

    @Test func refusesFilesInCopyPhases() throws {
        // Move data.json from Copy Bundle Resources into a Copy Files phase.
        let file = try classicCopy { text in
            text = text.replacingOccurrences(of: "isa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tC0B0000000000000000000B6 /* Assets.xcassets in Resources */,\n\t\t\t\tC0B0000000000000000000B8 /* data.json in Resources */,",
                with: "isa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 7;\n\t\t\tfiles = (\n\t\t\t\tC0B0000000000000000000B6 /* Assets.xcassets in Resources */,\n\t\t\t\tC0B0000000000000000000B8 /* data.json in Resources */,")
        }
        let (_, report) = try Migration.plan(file, wrapperExtensions: ["xcassets"])
        #expect(!report.converted.contains { $0.folder == "ClassicApp" })
        #expect(report.skipped.contains { $0.reason.contains("CopyFilesBuildPhase") })
    }

    @Test func isIdempotent() throws {
        let file = try classicCopy()
        let (plan, _) = try Migration.plan(file, wrapperExtensions: ["xcassets"])
        try plan.edits[0].updated.write(to: file.pbxprojURL)
        let (again, report) = try Migration.plan(try PBXProjectFile(projectURL: file.projectURL), wrapperExtensions: ["xcassets"])
        #expect(again.edits.isEmpty && report.converted.isEmpty)
    }
}

@Suite struct ComponentTemplateTests {
    func instantiate(_ template: String, host: Bool = true) async throws -> [TemplateOutput] {
        let index = try await TemplateIndex.load()
        let file = try PBXProjectFile(projectURL: GoldenTemplateTests.root.appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj"))
        var context = TemplateContext(
            name: "Weather", projectName: "HelloApp", hostBundleIdentifier: "dev.sochi.HelloApp", hostProductName: "HelloApp",
            hostProductType: "com.apple.product-type.application", developmentTeam: nil, fullUserName: "Someone")
        if !host { context.hostBundleIdentifier = nil }
        return try TemplateEngine(index: index, specs: try await XcodeSpecs.load()).instantiate(
            try index.find(template), context: context, projectSettings: file.projectBuildSettings, configurations: ["Debug", "Release"])
    }

    @Test func watchAppForExistingIOSApp() async throws {
        let outputs = try await instantiate("watchos-app")
        // The companion chooser picks the choice that embeds into the existing app: one watchOS target, no new iOS app.
        #expect(outputs.map(\.targetName) == ["Weather Watch App"])
        let watch = try #require(outputs.first)
        #expect(watch.isComponent && watch.injectInto == nil && watch.productName == "Weather Watch App")
        #expect(watch.settings["Debug"]?["SDKROOT"] == .string("watchos"))
        if case .string(let id)? = watch.settings["Debug"]?["PRODUCT_BUNDLE_IDENTIFIER"] { #expect(id.hasPrefix("dev.sochi.HelloApp.")) }
    }

    @Test func iMessageAppEmbedsItsExtensionInItsOwnApp() async throws {
        let outputs = try await instantiate("imessage-app")
        #expect(outputs.count == 2)
        let (app, ext) = (outputs[0], outputs[1])
        #expect(ext.injectInto != nil && ext.injectInto == app.targetIdentifier)
        guard case .string(let appID)? = app.settings["Debug"]?["PRODUCT_BUNDLE_IDENTIFIER"],
              case .string(let extID)? = ext.settings["Debug"]?["PRODUCT_BUNDLE_IDENTIFIER"] else { Issue.record("no bundle IDs"); return }
        // A new app beside the host takes the host's organization prefix; its extension nests under it exactly once.
        #expect(appID == "dev.sochi.Weather")
        #expect(extID == "dev.sochi.Weather.MessagesExtension")
    }
}

@Suite struct InfoPlistAndVerifierTests {
    @Test func reusesTheTargetsExceptionSet() throws {
        let fixture = GoldenTemplateTests.root.appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj")
        let file = try PBXProjectFile(projectURL: fixture)
        let target = file.targets[0]
        var writer = PBXTextWriter(file.text)
        try writer.addMembershipException("Info.plist", group: "AA0000000000000000000002", target: target, objects: file.objects)
        let once = try PBXProjectFile(projectURL: fixture, text: writer.text)
        var again = PBXTextWriter(once.text)
        try again.addMembershipException("Notes.md", group: "AA0000000000000000000002", target: target, objects: once.objects)
        try again.addMembershipException("Info.plist", group: "AA0000000000000000000002", target: target, objects: once.objects)
        let objects = try PBXProjectFile.objects(in: again.text, path: "x")
        let sets = objects.values.filter { $0["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet" }
        #expect(sets.count == 1)
        #expect(sets.first?["membershipExceptions"] as? [String] == ["Info.plist", "Notes.md"])
    }

    @Test func collectsCompiledSourcesPerTarget() {
        let collector = InventoryCollector(root: "/p")
        collector.consume(#"SwiftCompile normal arm64 Compiling\ A.swift,\ My\ File.swift /p/App/A.swift /p/App/My\ File.swift /tmp/obj/Gen.swift (in target 'App' from project 'P')"#)
        collector.consume(#"CompileC /tmp/obj/util.o /p/App/util.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'App' from project 'P')"#)
        collector.consume(#"CompileC /tmp/obj/vers.o /tmp/obj/DerivedSources/vers.c normal arm64 c x (in target 'Kit' from project 'P')"#)
        #expect(collector.sources == ["App": ["App/A.swift", "App/My File.swift", "App/util.c"]])
        var before = BuildInventory(sources: collector.sources, products: ["App.app": ["App", "data.json"]])
        var after = before
        after.products["App.app"] = ["App", "data.json", "README.md"]
        #expect(after.differences(from: before) == ["App.app: now contains README.md"])
        before.sources["App"]?.remove("App/util.c")
        #expect(after.differences(from: before).contains("App: now compiles App/util.c"))
    }
}

/// `sochi migrate --move-files`: virtual groups get real folders by moving files, safely.
@Suite struct ReorganizerTests {
    /// The classic fixture plus a virtual "Support" group holding Info.plist (referenced by INFOPLIST_FILE).
    func project(extra: (inout String) -> Void = { _ in }, files: [String: String] = [:]) throws -> PBXProjectFile {
        try MigrationTests().classicCopy(edit: { text in
            text = text.replacingOccurrences(of: "\t\t\t\tC0F0000000000000000000F7 /* Info.plist */,\n", with: "\t\t\t\tC0G000000000000000000G08 /* Support */,\n")
            text = text.replacingOccurrences(of: "/* End PBXGroup section */", with: """
                		C0G000000000000000000G08 /* Support */ = {
                			isa = PBXGroup;
                			children = (
                				C0F0000000000000000000F7 /* Info.plist */,
                			);
                			name = Support;
                			sourceTree = "<group>";
                		};
                /* End PBXGroup section */
                """)
            extra(&text)
        }, extraFiles: files)
    }

    @Test func plansMovesAndRewritesSettings() throws {
        let plan = try Reorganizer.plan(try project())
        #expect(plan.moves.contains(.init(from: "ClassicApp/Info.plist", to: "ClassicApp/Support/Info.plist")))
        #expect(plan.moves.contains(.init(from: "Notes.md", to: "Docs/Notes.md")))
        #expect(plan.text.contains("INFOPLIST_FILE = ClassicApp/Support/Info.plist;"))
        let objects = try PBXProjectFile.objects(in: plan.text, path: "x")
        let support = objects["C0G000000000000000000G08"]!
        #expect(support["path"] as? String == "Support" && support["name"] == nil)
        #expect(objects["C0F0000000000000000000F7"]?["path"] as? String == "Info.plist")
    }

    @Test func refusesPathsUsedWhereItCantRewrite() throws {
        let plan = try Reorganizer.plan(try project(files: ["Config/Base.xcconfig": "INFOPLIST_FILE = ClassicApp/Info.plist\n"]))
        #expect(!plan.moves.contains { $0.from == "ClassicApp/Info.plist" })
        #expect(plan.skipped.contains { $0.group == "Support" && $0.reason.contains("Base.xcconfig") })
        // Other groups still move.
        #expect(plan.moves.contains { $0.from == "Notes.md" })
    }

    @Test func refusesExistingDestinations() throws {
        let plan = try Reorganizer.plan(try project(files: ["ClassicApp/Support/Info.plist": "different"]))
        #expect(plan.skipped.contains { $0.group == "Support" && $0.reason.contains("already exists") })
    }

    @Test func movesAndUndoesCleanly() throws {
        let file = try project()
        let plan = try Reorganizer.plan(file)
        let root = file.projectDirectory
        let undo = try Reorganizer.perform(plan)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Support/Info.plist").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Info.plist").path))
        undo()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Info.plist").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes.md").path))
        // Folders it created are gone again.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Support").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Docs").path))
    }

    @Test func editsKeysInXcodesLayout() {
        var writer = PBXTextWriter("""
        \t\tA1 /* x */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = Old; path = "a/b c.swift"; sourceTree = SOURCE_ROOT; };
        \t\tG1 /* g */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t);
        \t\t\tname = Support;
        \t\t\tsourceTree = "<group>";
        \t\t};
        """)
        writer.setKeys(["path": "b c.swift", "sourceTree": "<group>"], removing: ["name"], of: "A1")
        writer.setKeys(["path": "Support"], removing: ["name"], of: "G1")
        #expect(writer.lines[0] == "\t\tA1 /* x */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"b c.swift\"; sourceTree = \"<group>\"; };")
        #expect(writer.lines.contains("\t\t\tpath = Support;") && !writer.lines.contains("\t\t\tname = Support;"))
        #expect(writer.lines.firstIndex(of: "\t\t\tpath = Support;")! < writer.lines.firstIndex(of: "\t\t\tsourceTree = \"<group>\";")!)
    }
}

@Suite struct ProjectCreatorTests {
    @Test func skeletonIsAValidEmptyProject() throws {
        let text = ProjectCreator.skeleton(
            name: "Weather", settings: ["Debug": ["SDKROOT": .string("iphoneos"), "GCC_PREPROCESSOR_DEFINITIONS": .list(["DEBUG=1", "$(inherited)"])],
                                        "Release": ["SDKROOT": .string("iphoneos")]],
            toolsVersion: "27.0")
        let file = try PBXProjectFile(projectURL: URL(fileURLWithPath: "/tmp/Weather.xcodeproj"), text: text)
        #expect(file.objectVersion == 77 && file.targets.isEmpty)
        #expect(file.projectConfigurationNames == ["Debug", "Release"])
        #expect(file.projectBuildSettings["Debug"]?["GCC_PREPROCESSOR_DEFINITIONS"] as? [String] == ["DEBUG=1", "$(inherited)"])
        #expect(text.contains("LastUpgradeCheck = 2700;"))
    }

    @Test func wiresTestBundlesToTheTestedApp() {
        var unit: [String: TargetSpec.Setting] = [:]
        TestWiring.apply(to: &unit, productType: "com.apple.product-type.bundle.unit-test", testedName: "Weather",
                         copied: ["IPHONEOS_DEPLOYMENT_TARGET": "18.0"])
        #expect(unit["TEST_HOST"] == .string("$(BUILT_PRODUCTS_DIR)/Weather.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Weather"))
        #expect(unit["BUNDLE_LOADER"] == .string("$(TEST_HOST)"))
        #expect(unit["IPHONEOS_DEPLOYMENT_TARGET"] == .string("18.0"))
        var ui: [String: TargetSpec.Setting] = [:]
        TestWiring.apply(to: &ui, productType: "com.apple.product-type.bundle.ui-testing", testedName: "Weather", copied: [:])
        #expect(ui == ["TEST_TARGET_NAME": .string("Weather")])
    }
}

@Suite struct TOMLTests {
    @Test func parsesTheSubsetSochiUses() throws {
        let doc = try TOML.parse("""
            # comment
            title = "sochi" # trailing
            [packages.swift-dependencies]
            url = "https://github.com/pointfreeco/swift-dependencies"
            from = '1.4.0'
            products = { App = ["Dependencies"], "My Widget" = [
                "DependenciesMacros",
            ] }
            [packages]
            mykit = { path = "../MyKit", products = { App = ["MyKit"] } }
            """)
        #expect(doc["title"]?.string == "sochi")
        let deps = try #require(doc["packages"]?["swift-dependencies"])
        #expect(deps["from"]?.string == "1.4.0")
        #expect(deps["products"]?["My Widget"]?.array == [.string("DependenciesMacros")])
        #expect(doc["packages"]?["mykit"]?["path"]?.string == "../MyKit")
    }

    @Test func rejectsWhatItDoesntSupport() {
        #expect(throws: TOML.ParseError.self) { try TOML.parse("a = 1.5") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("[[things]]") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("a = \"x\"\na = \"y\"") }
    }
}

@Suite struct SochiConfigTests {
    let remote = PackageSpec(identity: "swift-dependencies",
                             source: .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .upToNextMajor("1.4.0")),
                             products: ["App": ["Dependencies"]])

    @Test func writesBlocksAndKeepsTheRestOfTheFile() throws {
        var config = try SochiConfig(url: URL(fileURLWithPath: "/tmp/sochi.toml"), text: "# my notes\n[other]\nkeep = true\n")
        try config.set(remote)
        try config.set(PackageSpec(identity: "mykit", source: .local(path: "../MyKit"), products: ["App": ["MyKit"]]))
        #expect(config.packages.map(\.identity) == ["swift-dependencies", "mykit"])
        #expect(config.text.hasPrefix("# my notes\n[other]\nkeep = true\n"))
        #expect(config.text.contains("[packages.swift-dependencies]\nurl = \"https://github.com/pointfreeco/swift-dependencies\"\nfrom = \"1.4.0\"\nproducts = { App = [\"Dependencies\"] }"))

        var changed = remote
        changed.source = .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .exact("1.5.0"))
        try config.set(changed)
        #expect(config.packages.first == changed)
        try config.remove("swift-dependencies")
        #expect(config.packages.map(\.identity) == ["mykit"])
        #expect(config.text.contains("keep = true"))
    }

    @Test func readsTheInlineFormAndRequirements() throws {
        let config = try SochiConfig(url: URL(fileURLWithPath: "/tmp/sochi.toml"), text: """
            [packages]
            a = { url = "https://x/a.git", range = "1.0.0..<2.0.0", products = { App = ["A"] } }
            b = { url = "https://x/b", branch = "main" }
            """)
        #expect(config.packages[0].source == .remote(url: "https://x/a.git", requirement: .range("1.0.0", "2.0.0")))
        #expect(config.packages[1].source == .remote(url: "https://x/b", requirement: .branch("main")))
        #expect(PackageSpec.identity(of: "https://github.com/Simperium/simperium-ios/") == "simperium-ios")
        #expect(PackageSpec.identity(of: "git@github.com:pointfreeco/Swift-Dependencies.git") == "swift-dependencies")
    }
}

@Suite struct ProjectPackagesTests {
    static let fixture = GoldenTemplateTests.root.appendingPathComponent("Fixtures/HelloApp/HelloApp.xcodeproj")

    @Test func roundTripsEditsInXcodesFormat() throws {
        let file = try PBXProjectFile(projectURL: Self.fixture)
        #expect(ProjectPackages(file).specs.isEmpty)
        let deps = PackageSpec(identity: "swift-dependencies",
                               source: .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .upToNextMajor("1.4.0")),
                               products: ["HelloApp": ["Dependencies", "DependenciesMacros"]])
        let kit = PackageSpec(identity: "mykit", source: .local(path: "../MyKit"), products: ["HelloApp": ["MyKit"]])
        let added = try PBXProjectFile(projectURL: Self.fixture, text: try ProjectPackages.edit(file, set: [deps, kit], remove: []))
        let read = ProjectPackages(added)
        #expect(read.specs["swift-dependencies"] == deps && read.specs["mykit"] == kit)
        #expect(added.text.contains("requirement = {\n\t\t\t\tkind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = 1.4.0;\n\t\t\t};"))
        #expect(added.text.contains("productRef = "))

        // Change the requirement and drop one product; then remove the package entirely.
        var narrowed = deps
        narrowed.source = .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .exact("1.6.0"))
        narrowed.products = ["HelloApp": ["Dependencies"]]
        let changed = try PBXProjectFile(projectURL: Self.fixture, text: try ProjectPackages.edit(added, set: [narrowed], remove: []))
        #expect(ProjectPackages(changed).specs["swift-dependencies"] == narrowed)
        #expect(!changed.text.contains("DependenciesMacros"))
        let removed = try PBXProjectFile(projectURL: Self.fixture, text: try ProjectPackages.edit(changed, set: [], remove: ["swift-dependencies"]))
        #expect(ProjectPackages(removed).specs.keys.sorted() == ["mykit"])
        #expect(!removed.text.contains("swift-dependencies"))
    }

    @Test func readsSimplenotesRealPackageSection() throws {
        // Excerpt of Simplenote's project, as Xcode wrote it.
        let text = """
        // !$*UTF8*$!
        {
        \tobjectVersion = 77;
        \tobjects = {
        \t\tB1 /* ScreenObject in Frameworks */ = {isa = PBXBuildFile; productRef = D1 /* ScreenObject */; };
        \t\tT1 /* Simplenote */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tname = Simplenote;
        \t\t\tpackageProductDependencies = (
        \t\t\t\tD1 /* ScreenObject */,
        \t\t\t);
        \t\t};
        \t\tP1 /* Project object */ = {
        \t\t\tisa = PBXProject;
        \t\t\tpackageReferences = (
        \t\t\t\tR1 /* XCRemoteSwiftPackageReference "ScreenObject" */,
        \t\t\t\tR2 /* XCRemoteSwiftPackageReference "simperium-ios" */,
        \t\t\t);
        \t\t\ttargets = (
        \t\t\t\tT1 /* Simplenote */,
        \t\t\t);
        \t\t};
        \t\tR1 /* XCRemoteSwiftPackageReference "ScreenObject" */ = {
        \t\t\tisa = XCRemoteSwiftPackageReference;
        \t\t\trepositoryURL = "https://github.com/Automattic/ScreenObject";
        \t\t\trequirement = {
        \t\t\t\tkind = upToNextMajorVersion;
        \t\t\t\tminimumVersion = 0.3.0;
        \t\t\t};
        \t\t};
        \t\tR2 /* XCRemoteSwiftPackageReference "simperium-ios" */ = {
        \t\t\tisa = XCRemoteSwiftPackageReference;
        \t\t\trepositoryURL = "https://github.com/Simperium/simperium-ios/";
        \t\t\trequirement = {
        \t\t\t\tbranch = "v1.9.1-beta.2";
        \t\t\t\tkind = branch;
        \t\t\t};
        \t\t};
        \t\tD1 /* ScreenObject */ = {
        \t\t\tisa = XCSwiftPackageProductDependency;
        \t\t\tpackage = R1 /* XCRemoteSwiftPackageReference "ScreenObject" */;
        \t\t\tproductName = ScreenObject;
        \t\t};
        \t};
        \trootObject = P1 /* Project object */;
        }
        """
        let packages = ProjectPackages(try PBXProjectFile(projectURL: URL(fileURLWithPath: "/tmp/S.xcodeproj"), text: text))
        #expect(packages.specs["screenobject"]?.products == ["Simplenote": ["ScreenObject"]])
        #expect(packages.specs["screenobject"]?.source == .remote(url: "https://github.com/Automattic/ScreenObject", requirement: .upToNextMajor("0.3.0")))
        #expect(packages.specs["simperium-ios"]?.source == .remote(url: "https://github.com/Simperium/simperium-ios/", requirement: .branch("v1.9.1-beta.2")))
    }
}

/// Two-way sync decisions between sochi.toml and the project (no network: planning only).
@Suite struct PackageSyncTests {
    let deps = PackageSpec(identity: "swift-dependencies",
                           source: .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .upToNextMajor("1.4.0")),
                           products: ["HelloApp": ["Dependencies"]])

    /// A HelloApp copy whose project declares `projectSpecs`, with an optional sochi.toml and sync snapshot.
    func setup(project projectSpecs: [PackageSpec], config: [PackageSpec]?, base: [PackageSpec]?) throws -> (String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sochi-sync-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: GoldenTemplateTests.root.appendingPathComponent("Fixtures/HelloApp"), to: dir)
        let projectURL = dir.appendingPathComponent("HelloApp.xcodeproj")
        let file = try PBXProjectFile(projectURL: projectURL)
        try ProjectPackages.edit(file, set: projectSpecs, remove: []).write(to: file.pbxprojURL, atomically: true, encoding: .utf8)
        if let config {
            var toml = SochiConfig.new(projectDirectory: dir)
            for spec in config { try toml.set(spec) }
            try toml.write()
        }
        let project = XcodeProject(kind: .project, url: projectURL)
        if let base { PackageManager.saveBase(Dictionary(base.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a }), for: project) }
        return (dir.path, {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: PackageManager.baseURL(project).deletingLastPathComponent())
        })
    }

    func edited(_ outcome: PackageManager.Outcome) -> Set<String> { Set(outcome.plan.edits.map(\.url.lastPathComponent)) }

    @Test func createsSochiTomlFromTheProject() throws {
        let (path, cleanup) = try setup(project: [deps], config: nil, base: nil)
        defer { cleanup() }
        let outcome = try PackageManager.planSync(path: path, force: true)
        #expect(edited(outcome) == ["sochi.toml"])
        let toml = String(decoding: outcome.plan.edits[0].updated, as: UTF8.self)
        #expect(toml.contains("[packages.swift-dependencies]") && toml.contains("from = \"1.4.0\""))
    }

    @Test func carriesHandEditsIntoTheProject() throws {
        var newer = deps
        newer.source = .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .exact("1.5.0"))
        let (path, cleanup) = try setup(project: [deps], config: [newer], base: [deps])
        defer { cleanup() }
        let outcome = try PackageManager.planSync(path: path, force: true)
        #expect(edited(outcome) == ["project.pbxproj"])
        #expect(outcome.notes.contains { $0.contains("sochi.toml changed it") })
    }

    @Test func carriesXcodeChangesIntoSochiToml() throws {
        var older = deps
        older.source = .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .upToNextMajor("1.0.0"))
        let (path, cleanup) = try setup(project: [deps], config: [older], base: [older])
        defer { cleanup() }
        #expect(edited(try PackageManager.planSync(path: path, force: true)) == ["sochi.toml"])
    }

    @Test func removalsNeedEvidence() throws {
        // In the snapshot and still in the project, gone from sochi.toml: removed on purpose.
        let (path, cleanup) = try setup(project: [deps], config: [], base: [deps])
        defer { cleanup() }
        let outcome = try PackageManager.planSync(path: path, force: true)
        #expect(outcome.notes.contains { $0.contains("removed from sochi.toml") })
        // No snapshot (fresh clone): never delete, only add.
        let (fresh, cleanupFresh) = try setup(project: [deps], config: [], base: nil)
        defer { cleanupFresh() }
        let add = try PackageManager.planSync(path: fresh, force: true)
        #expect(edited(add) == ["sochi.toml"] && add.notes.contains { $0.contains("added in the project") })
    }

    @Test func refusesToGuessConflicts() throws {
        var a = deps, b = deps
        a.source = .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .exact("1.5.0"))
        b.source = .remote(url: "https://github.com/pointfreeco/swift-dependencies", requirement: .exact("1.6.0"))
        let (path, cleanup) = try setup(project: [a], config: [b], base: [deps])
        defer { cleanup() }
        #expect(throws: SochiError.self) { try PackageManager.planSync(path: path, force: true) }
    }
}
