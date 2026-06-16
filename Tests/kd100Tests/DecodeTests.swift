import XCTest
@testable import kd100

/// Tests the pure HID-report decoder: every physical press must fire exactly once
/// (key-up + auto-repeat filtered), the knob delta sign must be right, and the knob
/// press must edge-detect. No device required.
final class DecodeTests: XCTestCase {

    func testKeyboardFiresOncePerPress() {
        var d = ReportDecoder()
        // Press "7" (kb:00:2f). Buffer is [id, modifier, keycode, …].
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x2f]), ["kb:00:2f"])
        // Hardware auto-repeat re-sends the same non-idle report — must not re-fire.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x2f]), [])
        // Key-up (all zero) — no fire, resets the edge.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x00]), [])
        // Press again — fires.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x2f]), ["kb:00:2f"])
    }

    func testKeyboardModifierEncoding() {
        var d = ReportDecoder()
        // "plus-lower" = kb:07:11.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x07, 0x11]), ["kb:07:11"])
    }

    func testConsumerFiresOncePerPress() {
        var d = ReportDecoder()
        // "slash" = cc:ea (factory Vol−). Buffer is [id, usage].
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0xea]), ["cc:ea"])
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0xea]), [])   // repeat suppressed
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0x00]), [])   // release
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0xe9]), ["cc:e9"])  // a different key ("star")
    }

    func testKnobDirection() {
        var d = ReportDecoder()
        // delta +1 = clockwise.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x01]), ["dial:cw"])
        // delta 0xff (signed -1) = counter-clockwise.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0xff]), ["dial:ccw"])
        // No delta, no buttons → nothing.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x00]), [])
    }

    func testKnobPressEdgeDetected() {
        var d = ReportDecoder()
        // Press (button1 bit set).
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x01, 0x00]), ["dial:press"])
        // Held / auto-repeated (0x03 still has the 0x01 bit) — must not re-fire.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x03, 0x00]), [])
        // Release.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x00]), [])
        // Press again — fires.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x01, 0x00]), ["dial:press"])
    }

    func testKnobTurnAndPressInSameFrame() {
        var d = ReportDecoder()
        // A single report carrying both a CW delta and a fresh press → turn first.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x01, 0x01]), ["dial:cw", "dial:press"])
    }

    func testUnknownReportIgnored() {
        var d = ReportDecoder()
        XCTAssertEqual(d.decode(reportID: 9, bytes: [9, 0xaa, 0xbb]), [])
    }

    func testShortBuffersDoNotCrash() {
        var d = ReportDecoder()
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3]), [])
        XCTAssertEqual(d.decode(reportID: 1, bytes: []), [])
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17]), [])
    }
}
