import XCTest
@testable import kd100

/// Round-trip + tolerance tests for profile export/import. Pure data, no UI.
final class ProfileIOTests: XCTestCase {
    func testSingleProfileRoundTrips() {
        let bindings = ["1": "echo one", "knob-cw": "aerospace resize smart +50", "dot": ""]
        let data = ProfileIO.encodeProfile(name: "cTrader", bindings: bindings)
        let out = ProfileIO.decode(data)
        XCTAssertEqual(out?.count, 1)
        XCTAssertEqual(out?.first?.name, "cTrader")
        XCTAssertEqual(out?.first?.bindings["1"], "echo one")
        XCTAssertEqual(out?.first?.bindings["knob-cw"], "aerospace resize smart +50")
        XCTAssertEqual(out?.first?.bindings["dot"], "")
    }

    func testAllProfilesRoundTrip() {
        let data = ProfileIO.encodeAll([
            ("default", ["1": "aerospace workspace 1"]),
            ("cTrader", ["1": "echo ct", "knob-cw": ""]),
        ])
        let out = ProfileIO.decode(data)
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?.first?.name, "default")
        XCTAssertEqual(out?.last?.name, "cTrader")
        XCTAssertEqual(out?.last?.bindings["1"], "echo ct")
        XCTAssertEqual(out?.last?.bindings["knob-cw"], "")
    }

    func testDecodesLegacyFlatAsDefault() {
        let legacy = #"{ "bindings": { "7": "echo seven" } }"#.data(using: .utf8)!
        let out = ProfileIO.decode(legacy)
        XCTAssertEqual(out?.count, 1)
        XCTAssertEqual(out?.first?.name, "default")
        XCTAssertEqual(out?.first?.bindings["7"], "echo seven")
    }

    func testDecodesWholeConfigShape() {
        let cfg = #"{ "profiles": [ { "name": "default", "bindings": { "1": "a" } }, { "name": "X", "bindings": { "2": "b" } } ] }"#
            .data(using: .utf8)!
        let out = ProfileIO.decode(cfg)
        XCTAssertEqual(out?.map { $0.name }, ["default", "X"])
    }

    func testDropsUnknownKeys() {
        // A file with a bogus key must not smuggle it into a profile.
        let data = #"{ "name": "Junk", "bindings": { "1": "ok", "bogus-key": "nope" } }"#.data(using: .utf8)!
        let out = ProfileIO.decode(data)
        XCTAssertEqual(out?.first?.bindings["1"], "ok")
        XCTAssertNil(out?.first?.bindings["bogus-key"])
    }

    func testRejectsGarbage() {
        XCTAssertNil(ProfileIO.decode(Data("not json".utf8)))
        XCTAssertNil(ProfileIO.decode(Data(#"{ "unrelated": true }"#.utf8)))
    }
}
