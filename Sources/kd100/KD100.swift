import Foundation
import IOKit
import IOKit.hid

/// Opens the Huion KD100 over IOKit and either logs its events (capture) or
/// seizes the device and dispatches each control to an action (run).
final class KD100 {
    enum Mode { case capture, run }

    let vendorID = 0x256c
    let productID = 0x6d
    let reportLen = 64
    let mode: Mode
    let seize: Bool

    private var manager: IOHIDManager!
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private let mapping = Mapping()

    // Edge-detection state so each press fires once (ignore key-up + auto-repeat).
    private var kbIdle = true
    private var ccIdle = true
    private var knobButtonDown = false

    init(mode: Mode) {
        self.mode = mode
        self.seize = (mode == .run) // only the live daemon grabs the device
    }

    private func ts() -> String { String(format: "%9.3f", ProcessInfo.processInfo.systemUptime) }
    private func log(_ s: String) { print("\(ts())  \(s)") }

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            Unmanaged<KD100>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let opts: IOOptionBits = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                                        : IOOptionBits(kIOHIDOptionsTypeNone)
        let r = IOHIDManagerOpen(manager, opts)
        if r == kIOReturnSuccess {
            log("OPEN OK  mode=\(mode)  seize=\(seize)  vendor=0x\(String(vendorID, radix: 16)) product=0x\(String(productID, radix: 16))")
        } else {
            log("OPEN FAILED 0x\(String(format: "%08X", UInt32(bitPattern: r))) — grant Input Monitoring to this binary, then `launchctl kickstart -k`")
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        let pup = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
        let pu  = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
        log("device+ [\(name)] primaryUsagePage=0x\(String(format: "%04X", pup)) primaryUsage=0x\(String(format: "%02X", pu))")

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLen)
        buffers.append(buf)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(device, buf, reportLen, { context, _, _, _, reportID, report, length in
            guard let context = context else { return }
            Unmanaged<KD100>.fromOpaque(context).takeUnretainedValue()
                .handleReport(reportID: reportID, report: report, length: length)
        }, ctx)

        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context = context else { return }
            Unmanaged<KD100>.fromOpaque(context).takeUnretainedValue().handleValue(value)
        }, ctx)
    }

    private func handleValue(_ value: IOHIDValue) {
        let e = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(e))
        let usage = Int(IOHIDElementGetUsage(e))
        let v = IOHIDValueGetIntegerValue(value)
        switch mode {
        case .capture:
            if v == 0 { return } // skip key-up / idle elements to cut noise
            log("VALUE  page=0x\(String(format: "%04X", page)) usage=0x\(String(format: "%02X", usage)) (\(usage))  value=\(v)")
        case .run:
            dispatchValue(page: page, usage: usage, value: v)
        }
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        switch mode {
        case .capture:
            var hex = ""
            for i in 0..<length { hex += String(format: "%02x ", report[i]) }
            log("REPORT id=\(reportID) len=\(length): \(hex)")
        case .run:
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length { bytes[i] = report[i] }
            dispatchReport(id: Int(reportID), bytes: bytes)
        }
    }

    // MARK: - Dispatch

    // Unused in run mode (we dispatch off raw reports for uniform edge handling).
    private func dispatchValue(page: Int, usage: Int, value: Int) {}

    private func dispatchReport(id: Int, bytes: [UInt8]) {
        switch id {
        case 3: // keyboard boot report: [id][modifier][reserved][keycode]...
            let mod = bytes.count > 1 ? bytes[1] : 0
            let key = bytes.count > 2 ? bytes[2] : 0
            if mod == 0 && key == 0 { kbIdle = true; return }
            if kbIdle {
                kbIdle = false
                mapping.dispatch(String(format: "kb:%02x:%02x", mod, key))
            }

        case 1: // consumer report: [id][usage]
            let usage = bytes.count > 1 ? bytes[1] : 0
            if usage == 0 { ccIdle = true; return }
            if ccIdle {
                ccIdle = false
                mapping.dispatch(String(format: "cc:%02x", usage))
            }

        case 17: // vendor/knob report: [id][buttons][delta]...
            let b1 = bytes.count > 1 ? bytes[1] : 0
            let delta = bytes.count > 2 ? Int(Int8(bitPattern: bytes[2])) : 0
            if delta != 0 {
                mapping.dispatch(delta > 0 ? "dial:cw" : "dial:ccw")
            }
            let pressed = (b1 & 0x01) != 0   // button1 bit; 0x02 is the touch bit (ignored)
            if pressed && !knobButtonDown {
                knobButtonDown = true
                mapping.dispatch("dial:press")
            } else if !pressed {
                knobButtonDown = false
            }

        default:
            break
        }
    }
}
