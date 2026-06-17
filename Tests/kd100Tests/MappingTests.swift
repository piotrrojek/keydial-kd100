import XCTest
@testable import kd100

/// Tests config persistence (round-trip, defaults, update, reset) against a temp
/// file, plus the stderr cleaner. No device and no app required.
final class MappingTests: XCTestCase {
    private var tmpDir: URL!
    private var configPath: String!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kd100-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configPath = tmpDir.appendingPathComponent("mapping.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testFirstRunWritesDefaults() {
        let m = Mapping(path: configPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
        let cur = Dictionary(uniqueKeysWithValues: m.current().map { ($0.name, $0.cmd) })
        XCTAssertEqual(cur["1"], "aerospace workspace 1")
        XCTAssertEqual(cur["knob-cw"], "aerospace resize smart +50")
    }

    func testCurrentIsInPhysicalLayoutOrder() {
        let m = Mapping(path: configPath)
        XCTAssertEqual(m.current().map { $0.name }, Mapping.order)
    }

    func testWrittenFileIsValidJSONWithProfiles() throws {
        _ = Mapping(path: configPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["_note"])
        let profiles = obj?["profiles"] as? [[String: Any]]
        XCTAssertEqual(profiles?.count, 1)
        XCTAssertEqual(profiles?.first?["name"] as? String, "default")
        let bindings = profiles?.first?["bindings"] as? [String: String]
        XCTAssertEqual(bindings?["7"], "aerospace workspace 7")
    }

    func testUpdatePersistsAndReloads() {
        let m = Mapping(path: configPath)
        m.update(["7": "echo seven", "knob-press": ""])
        let cur = Dictionary(uniqueKeysWithValues: m.current().map { ($0.name, $0.cmd) })
        XCTAssertEqual(cur["7"], "echo seven")
        XCTAssertEqual(cur["knob-press"], "")   // blank disables

        // A fresh instance reading the same file sees the change.
        let m2 = Mapping(path: configPath)
        let cur2 = Dictionary(uniqueKeysWithValues: m2.current().map { ($0.name, $0.cmd) })
        XCTAssertEqual(cur2["7"], "echo seven")
        XCTAssertEqual(cur2["knob-press"], "")
    }

    func testResetToDefaults() {
        let m = Mapping(path: configPath)
        m.update(["1": "echo changed"])
        m.resetToDefaults()
        let cur = Dictionary(uniqueKeysWithValues: m.current().map { ($0.name, $0.cmd) })
        XCTAssertEqual(cur["1"], "aerospace workspace 1")
    }

    func testCommandWithQuotesAndBackslashesRoundTrips() {
        let m = Mapping(path: configPath)
        let tricky = #"osascript -e 'display notification "hi \"there\""'"#
        m.update(["minus": tricky])
        let m2 = Mapping(path: configPath)
        let cur = Dictionary(uniqueKeysWithValues: m2.current().map { ($0.name, $0.cmd) })
        XCTAssertEqual(cur["minus"], tricky)
    }

    func testCleanStderrFiltersZshArtifacts() {
        let noisy = "(eval):1: can't change option: zle\nreal error: command not found\n(eval):1: can't change option: zle"
        XCTAssertEqual(Mapping.cleanStderr(noisy), "real error: command not found")
    }

    func testCleanStderrEmptyOnPureNoise() {
        XCTAssertEqual(Mapping.cleanStderr("(eval):1: can't change option: zle\n"), "")
    }

    // MARK: - Profiles

    func testLegacyFlatFormatMigrates() throws {
        // An old-style single-set file (no `profiles` key) loads as the default profile.
        let legacy = #"{ "_note": "old", "bindings": { "1": "echo one", "7": "echo seven" } }"#
        try legacy.write(toFile: configPath, atomically: true, encoding: .utf8)
        let m = Mapping(path: configPath)
        let cur = Dictionary(uniqueKeysWithValues: m.current().map { ($0.name, $0.cmd) })
        XCTAssertEqual(cur["1"], "echo one")
        XCTAssertEqual(cur["7"], "echo seven")
        // Keys absent from the legacy file keep their built-in defaults (merge, not replace).
        XCTAssertEqual(cur["knob-cw"], "aerospace resize smart +50")
    }

    func testLegacyMatchKeyIsIgnoredAndDroppedOnSave() throws {
        // Files from the retired per-app-switching design carried a "match" bundle id.
        // It must load fine (the key is simply ignored) and never be written back.
        let legacy = #"{ "profiles": [ { "name": "default", "bindings": { "1": "echo one" } }, { "name": "cTrader", "match": "com.spotware.ctmac", "bindings": { "1": "echo ct" } } ] }"#
        try legacy.write(toFile: configPath, atomically: true, encoding: .utf8)
        let m = Mapping(path: configPath)
        XCTAssertEqual(m.profileNames(), ["default", "cTrader"])
        let b = Dictionary(uniqueKeysWithValues: m.bindings(forProfile: "cTrader").map { ($0.name, $0.cmd) })
        XCTAssertEqual(b["1"], "echo ct")
        // A write (round-trip the current profiles) must not re-emit "match".
        m.replaceAllProfiles(m.profileNames().map { n in
            (n, Dictionary(uniqueKeysWithValues: m.bindings(forProfile: n).map { ($0.name, $0.cmd) }))
        })
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(text.contains("\"match\""))
        XCTAssertFalse(text.contains("com.spotware.ctmac"))
    }

    func testCycleProfileSelectsActiveBindings() {
        let m = Mapping(path: configPath)
        m.replaceAllProfiles([
            ("default", Mapping.defaultsDict()),
            ("Term", ["1": "echo term-one"]),   // only overrides key 1
        ])

        // Starts on default.
        XCTAssertEqual(m.activeProfileName, "default")
        XCTAssertEqual(m.activeBinding(for: "1"), "aerospace workspace 1")

        // Knob press cycles to the next profile.
        XCTAssertEqual(m.cycleProfile(), "Term")
        XCTAssertEqual(m.activeProfileName, "Term")
        XCTAssertEqual(m.activeBinding(for: "1"), "echo term-one")           // profile wins
        XCTAssertEqual(m.activeBinding(for: "7"), "aerospace workspace 7")   // falls through to default

        // Wraps back to default.
        XCTAssertEqual(m.cycleProfile(), "default")
        XCTAssertEqual(m.activeProfileName, "default")
    }

    func testKnobPressDispatchCyclesProfileInsteadOfRunning() {
        let m = Mapping(path: configPath)
        m.addProfile(named: "T")   // [default, T]
        XCTAssertEqual(Mapping.profileSwitchControl, "knob-press")
        XCTAssertEqual(m.activeProfileName, "default")
        m.dispatch("dial:press")                       // raw HID id for knob-press
        XCTAssertEqual(m.activeProfileName, "T")
        m.dispatch("dial:press")
        XCTAssertEqual(m.activeProfileName, "default")  // wrapped
    }

    func testAddProfileRejectsDuplicateAndReservedName() {
        let m = Mapping(path: configPath)
        XCTAssertTrue(m.addProfile(named: "A"))
        XCTAssertFalse(m.addProfile(named: "A"))         // duplicate name
        XCTAssertFalse(m.addProfile(named: "default"))   // reserved
        XCTAssertEqual(m.profileNames().count, 2)
    }

    func testRemoveProfilePersistsAndDefaultIsProtected() {
        let m = Mapping(path: configPath)
        m.addProfile(named: "A")
        m.removeProfile("default")   // ignored — default can't be removed
        XCTAssertTrue(m.profileNames().contains("default"))
        m.removeProfile("A")
        XCTAssertEqual(m.profileNames().count, 1)
        // Persisted: a fresh instance reading the same file agrees.
        let m2 = Mapping(path: configPath)
        XCTAssertEqual(m2.profileNames().count, 1)
    }

    func testProfilesRoundTripThroughDisk() {
        let m = Mapping(path: configPath)
        m.replaceAllProfiles([
            ("default", Mapping.defaultsDict()),
            ("cTrader", ["1": "echo ct", "knob-cw": ""]),
        ])
        let m2 = Mapping(path: configPath)
        let names = m2.profileNames()
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names.last, "cTrader")
        let b = Dictionary(uniqueKeysWithValues: m2.bindings(forProfile: "cTrader").map { ($0.name, $0.cmd) })
        XCTAssertEqual(b["1"], "echo ct")
        XCTAssertEqual(b["knob-cw"], "")   // explicit disable preserved across round-trip
    }

    func testReplaceAllProfilesAlwaysKeepsDefaultFirst() {
        let m = Mapping(path: configPath)
        m.replaceAllProfiles([("X", ["1": "echo x"])])   // default omitted
        let names = m.profileNames()
        XCTAssertEqual(names.first, "default")   // re-inserted at the front
        XCTAssertTrue(names.contains("X"))
    }

    func testCycleProfileFiresCallback() {
        let m = Mapping(path: configPath)
        m.addProfile(named: "T")   // [default, T]
        var fired: [String] = []
        m.onActiveProfileChange = { fired.append($0) }
        XCTAssertEqual(m.cycleProfile(), "T")          // default -> T
        XCTAssertEqual(m.cycleProfile(), "default")    // T -> default (wrap)
        XCTAssertEqual(fired, ["T", "default"])
    }

    // MARK: - Knob velocity / continuous mode

    func testKnobOptionsDefaultAndRoundTrip() {
        let m = Mapping(path: configPath)
        XCTAssertFalse(m.knobSpinRepeat)   // off by default (back-compat)
        XCTAssertEqual(m.knobMaxRepeat, 4)

        m.knobSpinRepeat = true
        m.knobMaxRepeat = 25               // clamps into 1…20
        XCTAssertEqual(m.knobMaxRepeat, 20)
        m.replaceAllProfiles([("default", Mapping.defaultsDict())])   // persists everything

        let m2 = Mapping(path: configPath)
        XCTAssertTrue(m2.knobSpinRepeat)
        XCTAssertEqual(m2.knobMaxRepeat, 20)
    }

    func testKnobTurnDispatchReportsDirection() {
        let m = Mapping(path: configPath)
        m.identifyMode = true   // report via onControl but don't spawn a shell
        var seen: [String] = []
        m.onControl = { name, _, _ in seen.append(name) }
        m.dispatchKnobTurn(cw: true, delta: 1, velocity: 1)
        m.dispatchKnobTurn(cw: false, delta: 2, velocity: 5)
        XCTAssertEqual(seen, ["knob-cw", "knob-ccw"])
    }

    func testSpinRepeatRunsCommandOncePerDetent() {
        let m = Mapping(path: configPath)
        let out = tmpDir.appendingPathComponent("spin.log").path
        m.knobSpinRepeat = true
        m.knobMaxRepeat = 10
        m.update(["knob-cw": "printf x >> '\(out)'"])
        let done = expectation(description: "ran")
        m.onResult = { name, _, _ in if name == "knob-cw" { done.fulfill() } }
        m.dispatchKnobTurn(cw: true, delta: 3, velocity: 9)   // 3 detents → 3 appends, one shell
        wait(for: [done], timeout: 20)
        let written = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        XCTAssertEqual(written, "xxx")
    }

    func testSpinRepeatOffRunsOnce() {
        let m = Mapping(path: configPath)
        let out = tmpDir.appendingPathComponent("spin-off.log").path
        XCTAssertFalse(m.knobSpinRepeat)
        m.update(["knob-cw": "printf x >> '\(out)'"])
        let done = expectation(description: "ran")
        m.onResult = { name, _, _ in if name == "knob-cw" { done.fulfill() } }
        m.dispatchKnobTurn(cw: true, delta: 3, velocity: 9)   // delta ignored when spin is off
        wait(for: [done], timeout: 20)
        let written = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        XCTAssertEqual(written, "x")
    }
}
