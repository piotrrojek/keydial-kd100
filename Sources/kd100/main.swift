import Foundation

// kd100 — a userspace daemon for the Huion Keydial KD100 on macOS.
//
//   kd100 capture   observe-only: log every control's decoded value + raw HID
//                   report, across all interfaces (incl. the vendor knob).
//   kd100 run       seize the device and dispatch each control to an action
//                   (aerospace window-manager commands).
//
// Runs as a launchd LaunchAgent so it has its own Input Monitoring (TCC) identity.

setbuf(stdout, nil)
setbuf(stderr, nil)

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "capture"
let mode: KD100.Mode
switch arg {
case "capture": mode = .capture
case "run": mode = .run
default:
    FileHandle.standardError.write("usage: kd100 [capture|run]\n".data(using: .utf8)!)
    exit(2)
}

let daemon = KD100(mode: mode)
daemon.start()
CFRunLoopRun()
