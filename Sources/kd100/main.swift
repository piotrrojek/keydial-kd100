import AppKit
import Foundation

// kd100 — drive a Huion Keydial KD100 (18 keys + rotary knob) as a macOS
// shortcut pad, mapping each control to an arbitrary shell command.
//
//   kd100            menu-bar (tray) app: status, Settings (key→command editor),
//                    Open at Login, Quit. Runs the engine in seize mode.
//   kd100 run        headless: seize the device and dispatch each control to its
//                    command. (Used by a LaunchAgent / for debugging.)
//   kd100 capture    observe-only: log every control's decoded value + raw HID
//                    report, across all interfaces (incl. the vendor knob).
//
// Either form needs Input Monitoring (TCC), which attaches reliably only to a
// signed .app bundle — see scripts/install.sh.

setbuf(stdout, nil)
setbuf(stderr, nil)

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app"

switch command {
case "capture":
    let daemon = KD100(mode: .capture)
    daemon.start()
    CFRunLoopRun()

case "run":
    let daemon = KD100(mode: .run)
    daemon.start()
    CFRunLoopRun()

case "app":
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar only, no dock icon
    app.run()

default:
    FileHandle.standardError.write("usage: kd100 [app|run|capture]\n".data(using: .utf8)!)
    exit(2)
}
