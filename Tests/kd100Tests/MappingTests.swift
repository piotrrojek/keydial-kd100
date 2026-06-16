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

    func testWrittenFileIsValidJSONWithNote() throws {
        _ = Mapping(path: configPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["_note"])
        let bindings = obj?["bindings"] as? [String: String]
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
}
