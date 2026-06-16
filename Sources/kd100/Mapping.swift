import Foundation

/// Control → shell-command mapping.
///
/// Two layers:
///  1. `layout` — fixed, device-specific table: raw HID id → human key name.
///     The raw ids come from the HID report (`kb:MM:KK` keyboard, `cc:UU` consumer,
///     `dial:*` knob). This never changes for a given KD100.
///  2. `~/.config/kd100/mapping.json` — user-editable, keyed by the **human names**
///     → shell command. The menu-bar app's Settings window edits this file and
///     applies changes live (no restart). Hand-edits to the file are also picked up
///     live now, via a file watcher (`startWatching()`).
///
/// Commands run through the user's **login + interactive** shell (`$SHELL -ilc`) so
/// they inherit the same environment a terminal would — `PATH` additions, mise/asdf
/// shims, `~/.local/bin`, etc. (A bare hardcoded `PATH` silently failed to find
/// anything outside Homebrew.) Exit status and stderr are captured so a broken
/// binding is visible instead of failing silently.
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

    static let configNote = "key = KD100 physical key (numlock slash star minus / 7 8 9 plus-upper / 4 5 6 plus-lower / 1 2 3 enter / 0 dot / knob-cw knob-ccw knob-press); value = shell command run via your login shell ($SHELL -ilc). Edit in the menu-bar app's Settings window (applies live), or edit here — changes are picked up live."

    private let idToName: [String: String]
    private var bindings: [String: String] = [:]   // human name -> command (guarded by `lock`)
    let path: String

    /// Fired whenever a control is activated, on the HID callback thread. `cmd` is
    /// nil/empty when the key is unmapped; `executed` is false in identify mode or
    /// for an unmapped key. The tray app uses it to update the menu's "Last" line
    /// and to flash the matching key in an open Settings window.
    var onControl: ((_ name: String, _ cmd: String?, _ executed: Bool) -> Void)?

    /// Fired after a dispatched command finishes (not for `test(…)`, which uses its
    /// own completion). `stderrTail` is empty on success. The tray app surfaces
    /// non-zero exits in the menu so a broken binding is visible.
    var onResult: ((_ name: String, _ exitCode: Int32, _ stderrTail: String) -> Void)?

    /// Fired (on the main queue) when the config file changes on disk outside the
    /// app — so an open Settings window can refresh its fields.
    var onExternalChange: (() -> Void)?

    private let lock = NSLock()
    private var lastWrittenJSON: String?     // guarded by `lock`; suppresses self-write reloads
    private var _identifyMode = false        // guarded by `lock`
    private var watcher: FileWatcher?

    /// When true, controls are reported via `onControl` but their commands are NOT
    /// run — used by the Settings "Listen" mode so the user can press keys to locate
    /// them without firing workspace switches etc.
    var identifyMode: Bool {
        get { withLock { _identifyMode } }
        set { withLock { _identifyMode = newValue } }
    }

    @inline(__always) private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    init(path: String = NSString(string: "~/.config/kd100/mapping.json").expandingTildeInPath) {
        self.path = path
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

    // MARK: - Live reload

    /// Begin watching the config file so hand-edits apply without an app relaunch.
    func startWatching() {
        guard watcher == nil else { return }
        let w = FileWatcher(path: path) { [weak self] in self?.reloadFromDisk() }
        watcher = w
        w.start()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func reloadFromDisk() {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        if withLock({ text == lastWrittenJSON }) { return }  // ignore our own atomic write
        load()
        if let cb = onExternalChange { DispatchQueue.main.async { cb() } }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b = obj["bindings"] as? [String: String] else { return }
        withLock { for (name, cmd) in b { bindings[name] = cmd } }
    }

    /// Write the current bindings to the JSON file, in physical-layout order, with
    /// the explanatory note. Hand-rolled rather than JSONSerialization so the file
    /// stays human-friendly (stable order + the `_note`).
    private func persist() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let snap = withLock { bindings }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var lines: [String] = []
        for name in Mapping.order {
            lines.append("    \"\(name)\": \"\(esc(snap[name] ?? ""))\"")
        }
        let json = """
        {
          "_note": "\(esc(Mapping.configNote))",
          "bindings": {
        \(lines.joined(separator: ",\n"))
          }
        }
        """
        withLock { lastWrittenJSON = json }
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Read/write API for the Settings window

    /// Current bindings in physical-layout order (missing keys yield "").
    func current() -> [(name: String, cmd: String)] {
        let snap = withLock { bindings }
        return Mapping.order.map { ($0, snap[$0] ?? "") }
    }

    /// Replace the given bindings, persist to disk, and apply live.
    func update(_ newBindings: [String: String]) {
        withLock { for (name, cmd) in newBindings { bindings[name] = cmd } }
        persist()
    }

    /// Restore every key to its built-in default, persist, and apply live.
    func resetToDefaults() {
        withLock {
            bindings.removeAll()
            for (name, cmd) in Mapping.defaults { bindings[name] = cmd }
        }
        persist()
    }

    // MARK: - Dispatch

    /// Run the command bound to the control whose raw HID id is `rawID`.
    func dispatch(_ rawID: String) {
        guard let name = idToName[rawID] else { return }
        let cmd = withLock { bindings[name] }
        let willRun = !identifyMode && (cmd?.isEmpty == false)
        onControl?(name, cmd, willRun)
        guard willRun, let cmd = cmd else { return }
        execute(name: name, cmd: cmd, completion: nil)
    }

    /// Run an explicit command for a key (used by the Settings "test" button so the
    /// *current, possibly unsaved* field text is what runs). `completion` is invoked
    /// on the main queue with the exit status and a cleaned stderr tail.
    func test(name: String, command: String, completion: @escaping (Int32, String) -> Void) {
        guard !command.isEmpty else { return }
        execute(name: name, cmd: command) { code, tail in
            DispatchQueue.main.async { completion(code, tail) }
        }
    }

    /// Spawn `$SHELL -ilc <cmd>` and capture exit status + stderr without blocking
    /// (a `terminationHandler` finalizes, so a command that backgrounds a process
    /// can't pin a reader thread). stdout is discarded.
    private func execute(name: String, cmd: String, completion: ((Int32, String) -> Void)?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", cmd]
        p.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        p.standardError = errPipe
        let readHandle = errPipe.fileHandleForReading
        let bufQueue = DispatchQueue(label: "dev.otherlandlabs.kd100.stderr")
        var errData = Data()
        readHandle.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            bufQueue.sync { errData.append(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            readHandle.readabilityHandler = nil
            let tail = bufQueue.sync {
                Mapping.cleanStderr(String(data: errData, encoding: .utf8) ?? "")
            }
            let code = proc.terminationStatus
            if let completion { completion(code, tail) } else { self?.onResult?(name, code, tail) }
        }
        do {
            try p.run()
        } catch {
            readHandle.readabilityHandler = nil
            let msg = "launch failed: \(error.localizedDescription)"
            if let completion { completion(-1, msg) } else { onResult?(name, -1, msg) }
        }
    }

    /// Strip the harmless artifacts an interactive zsh emits when started without a
    /// tty (e.g. `(eval):1: can't change option: zle` from line-editor setup in the
    /// rc files), so a real failure's stderr tail isn't buried under shell noise.
    static func cleanStderr(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true)
         .filter { !$0.contains("can't change option:") }
         .joined(separator: "\n")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
