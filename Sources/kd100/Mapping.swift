import Foundation

/// Control → shell-command mapping.
///
/// Two layers:
///  1. `layout` — fixed, device-specific table: raw HID id → human key name.
///     The raw ids come from the HID report (`kb:MM:KK` keyboard, `cc:UU` consumer,
///     `dial:*` knob). This never changes for a given KD100.
///  2. `~/.config/kd100/mapping.json` — user-editable, keyed by the **human names**
///     → shell command. The menu-bar app's Settings window edits this file and
///     applies changes live (no restart). Editing the file by hand still works;
///     relaunch the app to pick those edits up.
final class Mapping {
    /// Physical layout (raw HID id → human key name). Rows 4/4/4/4/2; column 4 is
    /// the split-+ column (− +upper +lower Enter):
    ///   numlock  slash    star     minus
    ///   7        8        9        plus-upper
    ///   4        5        6        plus-lower
    ///   1        2        3        enter
    ///   0        dot
    /// plus the knob: knob-cw / knob-ccw / knob-press.
    static let layout: [(raw: String, name: String)] = [
        ("kb:00:01", "numlock"), ("cc:ea", "slash"), ("cc:e9", "star"), ("kb:08:0f", "minus"),
        ("kb:00:2f", "7"), ("kb:00:30", "8"), ("kb:00:05", "9"), ("kb:00:08", "plus-upper"),
        ("kb:00:0f", "4"), ("kb:01:07", "5"), ("kb:01:17", "6"), ("kb:07:11", "plus-lower"),
        ("kb:01:00", "1"), ("kb:04:00", "2"), ("kb:02:00", "3"), ("kb:05:1d", "enter"),
        ("kb:00:2c", "0"), ("kb:01:16", "dot"),
        ("dial:cw", "knob-cw"), ("dial:ccw", "knob-ccw"), ("dial:press", "knob-press"),
    ]

    /// Human key names in physical-layout order. The Settings window renders rows
    /// in this order; the JSON is written in this order too.
    static let order: [String] = layout.map { $0.name }

    /// The three knob actions — rendered as a separate section in Settings.
    static let knobNames: Set<String> = ["knob-cw", "knob-ccw", "knob-press"]

    /// Default command per human key name. Written to mapping.json on first run.
    static let defaults: [(name: String, cmd: String)] = [
        // Row 1: numlock slash star minus
        ("numlock",    "aerospace flatten-workspace-tree"),
        ("slash",      "aerospace workspace prev"),
        ("star",       "aerospace workspace next"),
        ("minus",      "aerospace move-node-to-monitor --wrap-around next --focus-follows-window"),
        // Row 2: 7 8 9 plus-upper
        ("7", "aerospace workspace 7"),
        ("8", "aerospace workspace 8"),
        ("9", "aerospace workspace 9"),
        ("plus-upper", "aerospace join-with left"),
        // Row 3: 4 5 6 plus-lower
        ("4", "aerospace workspace 4"),
        ("5", "aerospace workspace 5"),
        ("6", "aerospace workspace 6"),
        ("plus-lower", "aerospace join-with right"),
        // Row 4: 1 2 3 enter
        ("1", "aerospace workspace 1"),
        ("2", "aerospace workspace 2"),
        ("3", "aerospace workspace 3"),
        ("enter", "aerospace fullscreen"),
        // Row 5: 0 dot
        ("0",   "aerospace focus-monitor --wrap-around next"),
        ("dot", "aerospace layout floating tiling"),
        // Knob
        ("knob-cw",    "aerospace resize smart +50"),
        ("knob-ccw",   "aerospace resize smart -50"),
        ("knob-press", "aerospace balance-sizes"),
    ]

    static let configNote = "key = KD100 physical key (numlock slash star minus / 7 8 9 plus-upper / 4 5 6 plus-lower / 1 2 3 enter / 0 dot / knob-cw knob-ccw knob-press); value = shell command run via /bin/sh. Edit in the menu-bar app's Settings window (applies live), or edit here and relaunch the app."

    private let idToName: [String: String]
    private var bindings: [String: String] = [:]   // human name -> command
    let path = NSString(string: "~/.config/kd100/mapping.json").expandingTildeInPath

    /// Invoked whenever a control fires. `cmd` is nil/empty when the key is unmapped.
    /// Set by the tray app to surface "last input" in the menu. Fired on the HID
    /// callback thread (the run loop the manager was scheduled on).
    var onFire: ((_ name: String, _ cmd: String?) -> Void)?

    init() {
        var m = [String: String]()
        for e in Mapping.layout { m[e.raw] = e.name }
        idToName = m

        // Seed from defaults so a partial/broken/missing file still mostly works.
        for (name, cmd) in Mapping.defaults { bindings[name] = cmd }

        if FileManager.default.fileExists(atPath: path) {
            load()
        } else {
            persist()   // write the default config file on first run
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b = obj["bindings"] as? [String: String] else { return }
        for (name, cmd) in b { bindings[name] = cmd }
    }

    /// Write the current bindings to the JSON file, in physical-layout order, with
    /// the explanatory note. Hand-rolled rather than JSONSerialization so the file
    /// stays human-friendly (stable order + the `_note`).
    private func persist() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var lines: [String] = []
        for name in Mapping.order {
            lines.append("    \"\(name)\": \"\(esc(bindings[name] ?? ""))\"")
        }
        let json = """
        {
          "_note": "\(esc(Mapping.configNote))",
          "bindings": {
        \(lines.joined(separator: ",\n"))
          }
        }
        """
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Read/write API for the Settings window

    /// Current bindings in physical-layout order (missing keys yield "").
    func current() -> [(name: String, cmd: String)] {
        Mapping.order.map { ($0, bindings[$0] ?? "") }
    }

    /// Replace the given bindings, persist to disk, and apply live.
    func update(_ newBindings: [String: String]) {
        for (name, cmd) in newBindings { bindings[name] = cmd }
        persist()
    }

    /// Restore every key to its built-in default, persist, and apply live.
    func resetToDefaults() {
        bindings.removeAll()
        for (name, cmd) in Mapping.defaults { bindings[name] = cmd }
        persist()
    }

    // MARK: - Dispatch

    /// Run the command bound to the control whose raw HID id is `rawID`.
    func dispatch(_ rawID: String) {
        guard let name = idToName[rawID] else {
            print("FIRE \(rawID) (unknown key)")
            return
        }
        let cmd = bindings[name]
        onFire?(name, cmd)
        guard let cmd = cmd, !cmd.isEmpty else {
            print("FIRE \(name) -> (unmapped)")
            return
        }
        print("FIRE \(name) -> \(cmd)")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            p.environment = env
            try? p.run()
            p.waitUntilExit()
        }
    }
}
