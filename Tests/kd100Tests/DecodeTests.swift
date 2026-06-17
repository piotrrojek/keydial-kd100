import XCTest
@testable import kd100

/// Tests the pure HID-report decoder: every physical press must produce one `keyDown`
/// and one `keyUp` (the held-key re-send is filtered), the knob delta sign + magnitude
/// must be right, and the knob press must edge-detect. No device required.
final class DecodeTests: XCTestCase {

    func testKeyboardDownThenUp() {
        var d = ReportDecoder()
        // Press "7" (kb:00:2f). Buffer is [id, modifier, keycode, …].
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x2f]), [.keyDown("kb:00:2f")])
        // The device re-sends the same non-idle report while held — must not re-fire.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x2f]), [])
        // Key-up (all zero) — one keyUp naming the released key, resets the edge.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x00]), [.keyUp("kb:00:2f")])
        // A second release with nothing held — nothing.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x00]), [])
        // Press again — fires.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x00, 0x2f]), [.keyDown("kb:00:2f")])
    }

    func testKeyboardModifierEncoding() {
        var d = ReportDecoder()
        // "plus-lower" = kb:07:11.
        XCTAssertEqual(d.decode(reportID: 3, bytes: [3, 0x07, 0x11]), [.keyDown("kb:07:11")])
    }

    func testConsumerDownThenUp() {
        var d = ReportDecoder()
        // "slash" = cc:ea (factory Vol−). Buffer is [id, usage].
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0xea]), [.keyDown("cc:ea")])
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0xea]), [])                 // re-send suppressed
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0x00]), [.keyUp("cc:ea")])  // release names it
        XCTAssertEqual(d.decode(reportID: 1, bytes: [1, 0xe9]), [.keyDown("cc:e9")]) // a different key ("star")
    }

    func testKnobDirectionAndMagnitude() {
        var d = ReportDecoder()
        // delta +1 = clockwise, magnitude 1.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x01]), [.knobTurn(cw: true, delta: 1)])
        // delta +3 = a faster clockwise flick.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x03]), [.knobTurn(cw: true, delta: 3)])
        // delta 0xfd (signed -3) = counter-clockwise, magnitude 3.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0xfd]), [.knobTurn(cw: false, delta: 3)])
        // No delta, no buttons → nothing.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x00]), [])
    }

    func testKnobPressEdgeDetected() {
        var d = ReportDecoder()
        // Press (button1 bit set).
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x01, 0x00]), [.knobPress])
        // Held / re-sent (0x03 still has the 0x01 bit) — must not re-fire.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x03, 0x00]), [])
        // Release → one knobRelease.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x00, 0x00]), [.knobRelease])
        // Press again — fires.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x01, 0x00]), [.knobPress])
    }

    func testKnobTurnAndPressInSameFrame() {
        var d = ReportDecoder()
        // A single report carrying both a CW delta and a fresh press → turn first.
        XCTAssertEqual(d.decode(reportID: 17, bytes: [17, 0x01, 0x01]),
                       [.knobTurn(cw: true, delta: 1), .knobPress])
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

    // MARK: - Velocity

    func testVelocityRisesWithFasterSpin() {
        var v = KnobVelocity()
        // First detent seeds a modest rate.
        let slow = v.observe(cw: true, delta: 1, now: 0.0)
        // A detent 0.5s later is a long pause → fresh start, same modest seed.
        _ = v.observe(cw: true, delta: 1, now: 0.5)
        // Two detents 20ms apart = a fast spin → a much higher rate.
        _ = v.observe(cw: true, delta: 1, now: 0.52)
        let fast = v.observe(cw: true, delta: 1, now: 0.54)
        XCTAssertGreaterThan(fast, slow)
        XCTAssertGreaterThanOrEqual(slow, 1)
    }

    func testVelocityResetsOnDirectionChange() {
        var v = KnobVelocity()
        _ = v.observe(cw: true, delta: 1, now: 0.0)
        _ = v.observe(cw: true, delta: 1, now: 0.02)   // building up CW speed
        let afterFlip = v.observe(cw: false, delta: 1, now: 0.04)  // reverse → reseed, not carried over
        XCTAssertEqual(afterFlip, 10)   // the lone-detent seed (delta*10)
    }
}
