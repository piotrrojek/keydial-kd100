import XCTest
@testable import kd100

/// Tests the pure gesture state machine: a key with no secondary action taps instantly,
/// a hold fires on a timer while still down, and a double-tap resolves against the window.
/// Clock-injected, so no real time or hardware is needed.
final class GestureEngineTests: XCTestCase {
    private func makeEngine(hold: Set<String> = [], double: Set<String> = [])
        -> (GestureEngine, () -> [(String, KeyGesture)]) {
        let e = GestureEngine()
        e.config = GestureEngine.Config(holdSeconds: 0.35, doubleSeconds: 0.25)
        e.hasHold = { hold.contains($0) }
        e.hasDouble = { double.contains($0) }
        var fired: [(String, KeyGesture)] = []
        e.onGesture = { fired.append(($0, $1)) }
        return (e, { fired })
    }

    func testSimpleKeyFiresTapImmediately() {
        let (e, fired) = makeEngine()
        e.keyDown("1", at: 0)
        XCTAssertEqual(fired().map { $0.1 }, [.tap])   // no waiting, no latency
        XCTAssertFalse(e.hasPending)
        e.keyUp("1", at: 0.05)
        XCTAssertEqual(fired().count, 1)               // release doesn't re-fire
    }

    func testHoldFiresAfterThresholdAndSuppressesTap() {
        let (e, fired) = makeEngine(hold: ["enter"])
        e.keyDown("enter", at: 0)
        XCTAssertTrue(e.hasPending)
        e.tick(0.2)                                    // before the 0.35 threshold
        XCTAssertTrue(fired().isEmpty)
        e.tick(0.4)                                    // past it
        XCTAssertEqual(fired().map { $0.1 }, [.hold])
        e.keyUp("enter", at: 0.9)                      // release after a hold → no tap
        XCTAssertEqual(fired().map { $0.1 }, [.hold])
        XCTAssertFalse(e.hasPending)
    }

    func testHoldOnlyKeyTappedQuicklyFiresTap() {
        let (e, fired) = makeEngine(hold: ["enter"])
        e.keyDown("enter", at: 0)
        e.keyUp("enter", at: 0.1)                      // released early, no double bound → tap now
        XCTAssertEqual(fired().map { $0.1 }, [.tap])
        XCTAssertFalse(e.hasPending)
    }

    func testDoubleTapFires() {
        let (e, fired) = makeEngine(double: ["dot"])
        e.keyDown("dot", at: 0)
        e.keyUp("dot", at: 0.05)
        XCTAssertTrue(fired().isEmpty)                 // waits for a possible second tap
        XCTAssertTrue(e.hasPending)
        e.keyDown("dot", at: 0.15)                     // inside the 0.25 window
        XCTAssertEqual(fired().map { $0.1 }, [.double])
        e.keyUp("dot", at: 0.2)                        // the second release is swallowed
        XCTAssertEqual(fired().count, 1)
        XCTAssertFalse(e.hasPending)
    }

    func testSingleTapResolvesAfterDoubleWindowExpires() {
        let (e, fired) = makeEngine(double: ["dot"])
        e.keyDown("dot", at: 0)
        e.keyUp("dot", at: 0.05)
        e.tick(0.2)                                    // still inside the window
        XCTAssertTrue(fired().isEmpty)
        e.tick(0.31)                                   // 0.05 + 0.25 elapsed → it was just a tap
        XCTAssertEqual(fired().map { $0.1 }, [.tap])
        XCTAssertFalse(e.hasPending)
    }

    func testHoldAndDoubleCoexistOnOneKey() {
        let (e, fired) = makeEngine(hold: ["enter"], double: ["enter"])
        // Hold path.
        e.keyDown("enter", at: 0)
        e.tick(0.4)
        e.keyUp("enter", at: 0.5)
        // Double path.
        e.keyDown("enter", at: 1.0)
        e.keyUp("enter", at: 1.05)
        e.keyDown("enter", at: 1.15)
        XCTAssertEqual(fired().map { $0.1 }, [.hold, .double])
    }

    func testResetClearsState() {
        let (e, fired) = makeEngine(hold: ["enter"])
        e.keyDown("enter", at: 0)
        XCTAssertTrue(e.hasPending)
        e.reset()
        XCTAssertFalse(e.hasPending)
        e.tick(1.0)                                    // nothing to fire after a reset
        XCTAssertTrue(fired().isEmpty)
    }
}
