import Foundation
import IOKit
import IOKit.hid

/// Opens the Huion KD100 over IOKit and either logs its events (capture) or
/// seizes the device and dispatches each control to an action (run).
final class KD100 {
    enum Mode { case capture, run }

    /// Live state of the device connection, surfaced to the tray app's menu.
    enum Health {
        case waiting          // opened OK, no keypad present yet (or unplugged)
        case connected        // keypad seen and being read
        case needsPermission  // Input Monitoring (TCC) not granted
        case busy             // another process holds the device (Karabiner etc.)
        case error(String)    // any other IOHIDManagerOpen failure (hex code)
    }

    let vendorID = 0x256c
    let productID = 0x6d
    let reportLen = 64
    let mode: Mode
    let seize: Bool

    /// Exposed so the tray app shares one mapping instance (edits apply live).
    let mapping = Mapping()
    /// Set by the tray app to reflect connection/permission state in the menu.
    /// Invoked on the run loop the manager is scheduled on.
    var onHealth: ((Health) -> Void)?

    private var manager: IOHIDManager!
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    // Pure decoder: HID report → physical event(s), with press edge-detection so each
    // press fires once (held-key re-sends filtered). See Decode.swift.
    private var decoder = ReportDecoder()
    // Tracks knob spin speed (detents/sec) to surface as $KD100_VELOCITY. Pure helper,
    // fed the monotonic clock here in the live path.
    private var knobVelocity = KnobVelocity()

    // Turns key down/up edges into tap / hold / double-tap gestures. A run-loop timer
    // drives its deadlines (hold + double-tap) since the device sends nothing while a key
    // is merely held.
    private let gestures = GestureEngine()
    private var gestureTimer: Timer?
    private var lastListening = false   // detect Listen-mode toggles to reset gesture state

    init(mode: Mode) {
        self.mode = mode
        self.seize = (mode == .run) // only the live daemon grabs the device
        configureGestures()
    }

    private func configureGestures() {
        gestures.hasHold = { [weak self] in self?.mapping.hasHoldGesture($0) ?? false }
        gestures.hasDouble = { [weak self] in self?.mapping.hasDoubleGesture($0) ?? false }
        gestures.onGesture = { [weak self] name, g in self?.mapping.dispatchGesture(name: name, gesture: g) }
    }

    /// Keep a run-loop timer alive only while a hold/double deadline is pending.
    private func updateGestureTimer() {
        if gestures.hasPending {
            guard gestureTimer == nil else { return }
            let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.gestures.tick(ProcessInfo.processInfo.systemUptime)
                self.updateGestureTimer()
            }
            RunLoop.current.add(t, forMode: .common)
            gestureTimer = t
        } else {
            gestureTimer?.invalidate()
            gestureTimer = nil
        }
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

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context = context else { return }
            Unmanaged<KD100>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let opts: IOOptionBits = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                                        : IOOptionBits(kIOHIDOptionsTypeNone)
        let r = IOHIDManagerOpen(manager, opts)
        if r == kIOReturnSuccess {
            log("OPEN OK  mode=\(mode)  seize=\(seize)  vendor=0x\(String(vendorID, radix: 16)) product=0x\(String(productID, radix: 16))")
            onHealth?(.waiting)  // open succeeded; deviceAdded flips this to .connected
        } else {
            log("OPEN FAILED 0x\(String(format: "%08X", UInt32(bitPattern: r))) — grant Input Monitoring to this binary, then relaunch")
            switch r {
            case kIOReturnNotPermitted: onHealth?(.needsPermission)
            case kIOReturnExclusiveAccess: onHealth?(.busy)
            default: onHealth?(.error("0x\(String(format: "%08X", UInt32(bitPattern: r)))"))
            }
        }
    }

    private func deviceRemoved() {
        log("device-")
        onHealth?(.waiting)
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        let pup = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
        let pu  = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
        log("device+ [\(name)] primaryUsagePage=0x\(String(format: "%04X", pup)) primaryUsage=0x\(String(format: "%02X", pu))")
        onHealth?(.connected)

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
        // Listen mode locates keys immediately and without gesture timing; reset the
        // gesture state on the on/off transition so nothing stale lingers.
        let listening = mapping.identifyMode
        if listening != lastListening {
            lastListening = listening
            gestures.reset()
            updateGestureTimer()
        }

        for event in decoder.decode(reportID: id, bytes: bytes) {
            switch event {
            case .keyDown(let rawID):
                if listening {
                    mapping.dispatch(rawID)            // immediate locate, no timing
                } else if let name = mapping.name(forRawID: rawID) {
                    gestures.config.holdSeconds = Double(mapping.holdMs) / 1000
                    gestures.config.doubleSeconds = Double(mapping.doubleTapMs) / 1000
                    gestures.keyDown(name, at: ProcessInfo.processInfo.systemUptime)
                    updateGestureTimer()
                }
            case .keyUp(let rawID):
                if !listening, let name = mapping.name(forRawID: rawID) {
                    gestures.keyUp(name, at: ProcessInfo.processInfo.systemUptime)
                    updateGestureTimer()
                }
            case .knobPress:
                mapping.dispatch("dial:press")        // reserved: cycles profiles
            case .knobRelease:
                break
            case .knobTurn(let cw, let delta):
                let v = knobVelocity.observe(cw: cw, delta: delta,
                                             now: ProcessInfo.processInfo.systemUptime)
                mapping.dispatchKnobTurn(cw: cw, delta: delta, velocity: v)
            }
        }
    }
}
