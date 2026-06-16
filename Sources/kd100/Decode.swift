import Foundation

/// Pure HID-report → control-id decoder with press edge-detection.
///
/// Pulled out of `KD100` so it carries no IOKit dependency and can be unit-tested
/// without hardware. It holds the idle/down state needed so each physical press
/// fires exactly once — key-up reports and the device's auto-repeat are filtered.
///
/// The report buffers include the report-id byte at index 0 (the KD100 sends it),
/// so the payload starts at index 1, matching the `[id][…]` shapes documented in
/// the README:
///   - id 3  keyboard: `[id][modifier][reserved][keycode]`
///   - id 1  consumer: `[id][usage]`
///   - id 17 vendor/knob: `[id][buttons][delta]`
struct ReportDecoder {
    private var kbIdle = true
    private var ccIdle = true
    private var knobButtonDown = false

    /// Decode one input report into the raw control id(s) that should fire.
    /// Usually 0 or 1 ids, but a single knob report can carry both a turn delta
    /// and a press in the same frame, so the result is an ordered list (turn
    /// before press, matching the original dispatch order).
    mutating func decode(reportID: Int, bytes: [UInt8]) -> [String] {
        switch reportID {
        case 3: // keyboard boot report: [id][modifier][reserved][keycode]
            let mod = bytes.count > 1 ? bytes[1] : 0
            let key = bytes.count > 2 ? bytes[2] : 0
            if mod == 0 && key == 0 { kbIdle = true; return [] }
            guard kbIdle else { return [] }   // ignore auto-repeat until key-up
            kbIdle = false
            return [String(format: "kb:%02x:%02x", mod, key)]

        case 1: // consumer report: [id][usage]
            let usage = bytes.count > 1 ? bytes[1] : 0
            if usage == 0 { ccIdle = true; return [] }
            guard ccIdle else { return [] }
            ccIdle = false
            return [String(format: "cc:%02x", usage)]

        case 17: // vendor/knob report: [id][buttons][delta]
            var out: [String] = []
            let b1 = bytes.count > 1 ? bytes[1] : 0
            let delta = bytes.count > 2 ? Int(Int8(bitPattern: bytes[2])) : 0
            if delta != 0 { out.append(delta > 0 ? "dial:cw" : "dial:ccw") }
            let pressed = (b1 & 0x01) != 0   // button1 bit; 0x02 is the touch bit (ignored)
            if pressed && !knobButtonDown {
                knobButtonDown = true
                out.append("dial:press")
            } else if !pressed {
                knobButtonDown = false
            }
            return out

        default:
            return []
        }
    }
}
