import Foundation

/// One decoded *physical* event from the device. The decoder turns raw HID reports
/// into these; the dispatch layer turns them into actions (run a command, cycle a
/// profile, time a hold/double-tap gesture, …).
///
/// Keys carry their raw control id (`kb:MM:KK` / `cc:UU`) so `Mapping` can resolve
/// them through the layout table exactly as before. The knob is split out because it
/// behaves differently: a turn carries a **magnitude** (the device encodes spin speed
/// as a larger delta — 1, 2, 3 … — per the HID concurrency probe), and the centre
/// button has its own press/release edges.
enum DeviceEvent: Equatable {
    case keyDown(String)              // a keycap pressed (control id)
    case keyUp(String)                // the matching release
    case knobTurn(cw: Bool, delta: Int)   // one turn report; delta ≥ 1 = how far/fast
    case knobPress                    // centre button down
    case knobRelease                  // centre button up
}

/// Pure HID-report → `DeviceEvent` decoder with edge-detection.
///
/// Pulled out of `KD100` so it carries no IOKit dependency and can be unit-tested
/// without hardware. It holds the idle/down state needed so each physical press
/// fires a single `keyDown` (the device re-sends the held report; that's filtered)
/// and a single `keyUp` on release.
///
/// The report buffers include the report-id byte at index 0 (the KD100 sends it),
/// so the payload starts at index 1, matching the `[id][…]` shapes documented in
/// the README:
///   - id 3  keyboard: `[id][modifier][reserved][keycode]`
///   - id 1  consumer: `[id][usage]`
///   - id 17 vendor/knob: `[id][buttons][delta]`
///
/// Note on the keyboard interface: the boot report has a single keycode slot, and the
/// probe confirmed a held key swallows other keys — so at most one keyboard key and
/// one consumer key is "down" at a time. We remember which, so the all-zero release
/// report can name the key it releases.
struct ReportDecoder {
    private var lastKb: String?              // currently-down keyboard control id
    private var lastCc: String?              // currently-down consumer control id
    private var knobButtonDown = false

    /// Decode one input report into the physical event(s) it represents. Usually 0 or
    /// 1, but a single knob report can carry both a turn and a press in one frame, so
    /// the result is an ordered list (turn before press, matching dispatch order).
    mutating func decode(reportID: Int, bytes: [UInt8]) -> [DeviceEvent] {
        switch reportID {
        case 3: // keyboard boot report: [id][modifier][reserved][keycode]
            let mod = bytes.count > 1 ? bytes[1] : 0
            let key = bytes.count > 2 ? bytes[2] : 0
            if mod == 0 && key == 0 {                 // all-zero = release of the held key
                guard let id = lastKb else { return [] }
                lastKb = nil
                return [.keyUp(id)]
            }
            let id = String(format: "kb:%02x:%02x", mod, key)
            guard lastKb != id else { return [] }     // device re-sends the held report; ignore
            // A different non-zero id while one is held shouldn't happen (held keys
            // swallow others); if it does, treat it as a fresh press of the new key.
            lastKb = id
            return [.keyDown(id)]

        case 1: // consumer report: [id][usage]
            let usage = bytes.count > 1 ? bytes[1] : 0
            if usage == 0 {
                guard let id = lastCc else { return [] }
                lastCc = nil
                return [.keyUp(id)]
            }
            let id = String(format: "cc:%02x", usage)
            guard lastCc != id else { return [] }
            lastCc = id
            return [.keyDown(id)]

        case 17: // vendor/knob report: [id][buttons][delta]
            var out: [DeviceEvent] = []
            let b1 = bytes.count > 1 ? bytes[1] : 0
            let raw = bytes.count > 2 ? Int(Int8(bitPattern: bytes[2])) : 0
            if raw != 0 { out.append(.knobTurn(cw: raw > 0, delta: abs(raw))) }
            let pressed = (b1 & 0x01) != 0   // button1 bit; 0x02 is the touch bit (ignored)
            if pressed && !knobButtonDown {
                knobButtonDown = true
                out.append(.knobPress)
            } else if !pressed && knobButtonDown {
                knobButtonDown = false
                out.append(.knobRelease)
            }
            return out

        default:
            return []
        }
    }
}

/// Estimates how fast the knob is being turned, in **detents per second**, from the
/// stream of turn reports. Pure (the caller passes a monotonic clock) so it's testable
/// without real time.
///
/// The instantaneous rate of one report is `delta / Δt` since the previous same-direction
/// report; we exponentially smooth it so a single jittery gap doesn't spike the value,
/// and reset on a direction change or a pause (the user stopped and started again). The
/// result is surfaced to bound commands as `$KD100_VELOCITY` (with the raw magnitude as
/// `$KD100_DELTA`), so a script can scale its step to the spin.
struct KnobVelocity {
    private var lastTime: Double?
    private var lastCW: Bool?
    private var smoothed: Double = 0

    /// Gap (seconds) after which we treat the next turn as a fresh start, not a continuation.
    private let pauseGap = 0.4
    private let alpha = 0.5   // smoothing weight on the new sample

    /// Record a turn at time `now`; return the smoothed detents/second (≥ 1).
    mutating func observe(cw: Bool, delta: Int, now: Double) -> Int {
        defer { lastTime = now; lastCW = cw }
        guard let last = lastTime, lastCW == cw, now - last <= pauseGap, now > last else {
            smoothed = Double(delta) * 10   // a lone detent ≈ a slow tick; seed a modest rate
            return max(1, Int(smoothed.rounded()))
        }
        let instant = Double(delta) / (now - last)
        smoothed = smoothed * (1 - alpha) + instant * alpha
        return max(1, Int(smoothed.rounded()))
    }
}
