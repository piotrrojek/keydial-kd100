import Foundation

/// The three gestures a single key can produce.
enum KeyGesture: Equatable { case tap, hold, double }

/// Turns a key's raw down/up edges into a **tap**, a **hold** (the key stays down past a
/// threshold), or a **double-tap** (two quick taps).
///
/// Pure and clock-injected: the host feeds `keyDown`/`keyUp` with a monotonic time and
/// drives `tick(now:)` from a run-loop timer, so the hold + double-tap deadlines can
/// elapse even though the device sends no event while a key is simply held. That makes the
/// whole state machine unit-testable without real time or hardware.
///
/// Crucially, a key with **no** hold or double binding fires `tap` immediately on key-down
/// — zero added latency, identical to the pre-gesture behavior. The double-tap wait (and
/// its ~250 ms latency on the first tap) is paid only by keys that actually define a
/// double action; a hold-only key still taps instantly on release.
final class GestureEngine {
    struct Config: Equatable {
        var holdSeconds: Double = 0.35      // held longer than this → hold
        var doubleSeconds: Double = 0.25    // second tap within this of the first's release → double
    }
    var config = Config()

    /// Whether a key currently has a hold / double binding (host wires these to the mapping).
    /// When both are false for a key, it takes the immediate-tap fast path.
    var hasHold: (String) -> Bool = { _ in false }
    var hasDouble: (String) -> Bool = { _ in false }
    /// Emit a resolved gesture for a key.
    var onGesture: (String, KeyGesture) -> Void = { _, _ in }

    private enum State {
        case down(at: Double, holdFired: Bool)   // key is currently held
        case awaitingSecond(deadline: Double)    // released once; waiting for a 2nd tap
        case ignoreUp                            // a gesture fired this cycle; swallow the release
    }
    private var states: [String: State] = [:]

    /// True while some key has a deadline the timer still needs to drive.
    var hasPending: Bool {
        states.contains { name, s in
            switch s {
            case .down(_, let holdFired): return hasHold(name) && !holdFired   // hold deadline pending
            case .awaitingSecond:         return true                          // double-tap window open
            case .ignoreUp:               return false
            }
        }
    }

    func reset() { states.removeAll() }

    func keyDown(_ name: String, at t: Double) {
        let hold = hasHold(name), dbl = hasDouble(name)
        if !hold && !dbl {
            onGesture(name, .tap)                 // simple key: fire now, keep no state
            return
        }
        if case .awaitingSecond(let deadline)? = states[name], t <= deadline {
            onGesture(name, .double)              // the second tap landed in time
            states[name] = .ignoreUp
            return
        }
        states[name] = .down(at: t, holdFired: false)
    }

    func keyUp(_ name: String, at t: Double) {
        switch states[name] {
        case .down(_, let holdFired):
            if holdFired {
                states[name] = nil                // hold already fired; release just ends it
            } else if hasDouble(name) {
                states[name] = .awaitingSecond(deadline: t + config.doubleSeconds)
            } else {
                onGesture(name, .tap)             // hold-only key released early → tap
                states[name] = nil
            }
        case .ignoreUp:
            states[name] = nil
        default:
            break
        }
    }

    /// Drive elapsed deadlines (hold fired while still down; the double-tap window expiring
    /// into a plain tap). Safe to call at any cadence.
    func tick(_ now: Double) {
        for (name, state) in states {
            switch state {
            case .down(let at, false) where hasHold(name) && now >= at + config.holdSeconds:
                onGesture(name, .hold)
                states[name] = .down(at: at, holdFired: true)
            case .awaitingSecond(let deadline) where now >= deadline:
                onGesture(name, .tap)             // the awaited second tap never came
                states[name] = nil
            default:
                break
            }
        }
    }
}
