import Foundation

/// Control → shell-command mapping, with **per-app profiles**.
///
/// Three layers:
///  1. `layout` — fixed, device-specific table: raw HID id → human key name.
///     The raw ids come from the HID report (`kb:MM:KK` keyboard, `cc:UU` consumer,
///     `dial:*` knob). This never changes for a given KD100.
///  2. **Profiles** — a `default` profile plus optional named profiles. Switching is
///     **manual**: the knob press cycles to the next profile (`cycleProfile()`). There
///     is no automatic / frontmost-app switching — the user drives it explicitly.
///  3. `~/.config/kd100/mapping.json` — user-editable, keyed by the **human names**
///     → shell command, grouped per profile. The menu-bar app's Settings window
///     edits this file and applies changes live (no restart). Hand-edits are also
///     picked up live, via a file watcher (`startWatching()`).
///
/// Resolution: the active profile's binding wins; a key the active profile doesn't
/// define **falls through to `default`** (so an app profile only needs to list what
/// differs). A key bound to "" is explicitly disabled in that profile.
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

    /// Default command per human key name. Written to the `default` profile on first run.
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

    /// The built-in defaults as a dictionary (handy for seeding profiles).
    static func defaultsDict() -> [String: String] {
        Dictionary(uniqueKeysWithValues: Mapping.defaults.map { ($0.name, $0.cmd) })
    }

    static let configNote = "Profiles: \"default\" plus any named profiles you add. Switch between them manually with the knob press — it cycles default -> next -> default and is reserved app-wide, so it never runs a command. Within a profile, key = KD100 physical key (numlock slash star minus / 7 8 9 plus-upper / 4 5 6 plus-lower / 1 2 3 enter / 0 dot / knob-cw knob-ccw knob-press); value = shell command run via your login shell ($SHELL -ilc). A key omitted from a profile falls through to \"default\"; a key set to \"\" is disabled there. A key's value can be a string (its tap command) or an object {\"tap\":..., \"hold\":..., \"double\":...} to add a long-press and/or double-tap action (top-level holdMs / doubleTapMs tune the timing). A command of \"@toggle <profile>\" flips to that profile (a layer) and back, \"@profile <profile>\" switches to it, \"@cycle\" cycles — so a key can act as a layer toggle. knob-cw/knob-ccw commands always see $KD100_DELTA (this turn's magnitude) and $KD100_VELOCITY (smoothed detents/sec) in their environment. Top-level knobSpinRepeat (true/false) makes a fast spin run the knob command up to knobMaxRepeat times. Edit in the menu-bar app's Settings window (applies live), or edit here — changes are picked up live."

    /// One named binding set. Profiles are cycled manually by the knob press.
    ///
    /// `bindings` is the **tap** command per key. `hold` and `double` are optional second
    /// and third actions (long-press / double-tap) — sparse, present only for keys that
    /// define them. All three resolve with the same fall-through to the default profile.
    private struct Profile {
        var name: String            // display name + JSON key; "default" is reserved/required
        var bindings: [String: String]    // human name -> tap command
        var hold: [String: String] = [:]      // human name -> long-press command
        var double: [String: String] = [:]    // human name -> double-tap command
    }

    /// A profile's full binding set, used to pass tap+hold+double in one shot
    /// (`replaceAllProfiles`, `keyBindings(forProfile:)`).
    struct ProfileBindings {
        var name: String
        var tap: [String: String]
        var hold: [String: String] = [:]
        var double: [String: String] = [:]
    }

    private let idToName: [String: String]
    /// Profiles, guarded by `lock`. `profiles[0]` is always the `default` profile.
    private var profiles: [Profile] = []
    /// Index of the manually-selected active profile (guarded by `lock`). Advanced by
    /// the profile-switch control (the knob press).
    private var _activeIndex = 0
    /// The profile active before the last switch, so `@toggle` can flip back (guarded by `lock`).
    private var _previousIndex = 0
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

    /// Fired when the active profile changes (the knob press cycled to it).
    /// The tray app uses it to show the active profile in the menu.
    var onActiveProfileChange: ((_ name: String) -> Void)?

    private let lock = NSLock()
    private var lastWrittenJSON: String?     // guarded by `lock`; suppresses self-write reloads
    private var _identifyMode = false        // guarded by `lock`
    private var watcher: FileWatcher?

    // Knob velocity / continuous mode (global, not per-profile). Both guarded by `lock`.
    private var _knobSpinRepeat = false      // a fast spin runs the command multiple times
    private var _knobMaxRepeat = 4           // cap on that repeat count

    /// When on, a single fast knob turn (the device reports a delta > 1) runs the bound
    /// knob command that many times — so a quick flick covers several detents. Off by
    /// default, where every turn report fires exactly once. Either way the command always
    /// sees `$KD100_DELTA` (this report's magnitude) and `$KD100_VELOCITY` (smoothed
    /// detents/sec) in its environment, so a script can scale itself instead.
    var knobSpinRepeat: Bool {
        get { withLock { _knobSpinRepeat } }
        set { withLock { _knobSpinRepeat = newValue } }
    }
    /// Upper bound on the spin-repeat count (clamped to 1…20).
    var knobMaxRepeat: Int {
        get { withLock { _knobMaxRepeat } }
        set { withLock { _knobMaxRepeat = max(1, min(newValue, 20)) } }
    }

    // Gesture timing (global). Milliseconds; guarded by `lock`.
    private var _holdMs = 350     // press longer than this → hold
    private var _doubleMs = 250   // second tap within this → double-tap

    /// How long a key must stay down to count as a hold (150…1000 ms).
    var holdMs: Int {
        get { withLock { _holdMs } }
        set { withLock { _holdMs = max(150, min(newValue, 1000)) } }
    }
    /// The double-tap window — also the tap latency a double-bound key pays (120…600 ms).
    var doubleTapMs: Int {
        get { withLock { _doubleMs } }
        set { withLock { _doubleMs = max(120, min(newValue, 600)) } }
    }

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

        // Seed a default profile from the built-ins so a partial/broken/missing file
        // still mostly works.
        profiles = [Profile(name: "default", bindings: Mapping.defaultsDict())]

        if FileManager.default.fileExists(atPath: path) {
            load()
        } else {
            persist()   // write the default config file on first run
        }
    }

    // MARK: - Active-profile selection (manual; cycled by the profile-switch control)

    /// The physical control reserved app-wide to cycle profiles. It never runs a
    /// bound command in any profile — pressing it advances to the next profile and
    /// the tray reflects the change. (Chosen: the knob press.)
    static let profileSwitchControl = "knob-press"

    /// A **profile action** a key can be bound to (instead of a shell command), giving the
    /// "tap-to-toggle layer" behavior: bind a key's tap to `@toggle <name>` and it flips to
    /// that profile (a "layer") and back. (Hold-as-layer is hardware-impossible — a held key
    /// blocks all other keys — so toggling is the only viable layer model; see the probe.)
    enum ProfileAction: Equatable {
        case cycle              // "@cycle" / "@cycle-profile" — like the knob press
        case switchTo(String)   // "@profile <name>" — go to that profile (absolute)
        case toggle(String)     // "@toggle <name>" — flip between that profile and the previous
    }

    /// Parse a bound command as a profile action, or nil if it's an ordinary shell command.
    static func parseAction(_ command: String) -> ProfileAction? {
        let s = command.trimmingCharacters(in: .whitespaces)
        if s == "@cycle" || s == "@cycle-profile" { return .cycle }
        if s.hasPrefix("@profile ") {
            let n = String(s.dropFirst("@profile ".count)).trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : .switchTo(n)
        }
        if s.hasPrefix("@toggle ") {
            let n = String(s.dropFirst("@toggle ".count)).trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : .toggle(n)
        }
        return nil
    }

    /// Active index clamped into range. Lock held.
    private func safeActiveIndexLocked() -> Int {
        if profiles.isEmpty { return 0 }
        return min(max(_activeIndex, 0), profiles.count - 1)
    }

    /// The active profile's display name (for the menu + menu-bar label).
    var activeProfileName: String { withLock { profiles[safeActiveIndexLocked()].name } }

    /// Advance to the next profile (wrapping), fire `onActiveProfileChange`, and
    /// return the new active profile name.
    @discardableResult
    func cycleProfile() -> String {
        let name: String = withLock {
            guard !profiles.isEmpty else { return "default" }
            _previousIndex = safeActiveIndexLocked()
            _activeIndex = (safeActiveIndexLocked() + 1) % profiles.count
            return profiles[_activeIndex].name
        }
        onActiveProfileChange?(name)
        return name
    }

    /// Switch to a named profile (absolute). No-op if it doesn't exist or is already active.
    func switchToProfile(named name: String) {
        let newName: String? = withLock {
            guard let idx = profiles.firstIndex(where: { $0.name == name }), idx != safeActiveIndexLocked()
            else { return nil }
            _previousIndex = safeActiveIndexLocked()
            _activeIndex = idx
            return profiles[idx].name
        }
        if let newName { onActiveProfileChange?(newName) }
    }

    /// Flip between a named profile (a "layer") and whatever was active before it: if that
    /// profile is active, go back to the previous one; otherwise switch to it.
    func toggleProfile(named name: String) {
        let newName: String? = withLock {
            let cur = safeActiveIndexLocked()
            if profiles[cur].name == name {
                let prev = min(max(_previousIndex, 0), profiles.count - 1)
                guard prev != cur else { return nil }
                _activeIndex = prev
                return profiles[_activeIndex].name
            } else {
                guard let idx = profiles.firstIndex(where: { $0.name == name }) else { return nil }
                _previousIndex = cur
                _activeIndex = idx
                return profiles[idx].name
            }
        }
        if let newName { onActiveProfileChange?(newName) }
    }

    /// Run a profile action (from a key bound to `@cycle` / `@profile …` / `@toggle …`).
    private func perform(_ action: ProfileAction) {
        switch action {
        case .cycle:            cycleProfile()
        case .switchTo(let n):  switchToProfile(named: n)
        case .toggle(let n):    toggleProfile(named: n)
        }
    }

    /// The command the *active* profile binds to `name`, falling through to the
    /// default profile for keys the active profile doesn't define. nil/"" means
    /// unmapped/disabled. Exposed for testing the resolution without executing.
    func activeBinding(for name: String) -> String? {
        withLock {
            let active = profiles[safeActiveIndexLocked()]
            return active.bindings[name] ?? profiles[0].bindings[name]
        }
    }

    /// The active profile's **hold** (long-press) command for `name`, falling through to
    /// default. nil/"" means no hold action — the key just taps.
    func activeHold(for name: String) -> String? {
        withLock {
            let active = profiles[safeActiveIndexLocked()]
            return active.hold[name] ?? profiles[0].hold[name]
        }
    }

    /// The active profile's **double-tap** command for `name`, falling through to default.
    func activeDouble(for name: String) -> String? {
        withLock {
            let active = profiles[safeActiveIndexLocked()]
            return active.double[name] ?? profiles[0].double[name]
        }
    }

    /// Whether `name` has a hold / double action in effect (the gesture engine asks these
    /// to decide whether a key needs press/release timing at all).
    func hasHoldGesture(_ name: String) -> Bool { activeHold(for: name)?.isEmpty == false }
    func hasDoubleGesture(_ name: String) -> Bool { activeDouble(for: name)?.isEmpty == false }

    /// Map a raw HID id to its human key name (for the gesture layer, which works in names).
    func name(forRawID rawID: String) -> String? { idToName[rawID] }

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
        onActiveProfileChange?(activeProfileName)   // active profile may have shifted/dropped
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Parse either the current profiles array or the legacy single `bindings` block.
        // Each per-key value is a bare string (tap only) or `{tap,hold?,double?}`.
        var parsed: [Profile] = []
        if let arr = obj["profiles"] as? [[String: Any]] {
            for pd in arr {
                guard let name = pd["name"] as? String, !name.isEmpty else { continue }
                // A legacy "match" key (from the retired per-app-switching design) is ignored.
                let (tap, hold, dbl) = Mapping.parseBindings(pd["bindings"] as? [String: Any] ?? [:])
                parsed.append(Profile(name: name, bindings: tap, hold: hold, double: dbl))
            }
        } else if let b = obj["bindings"] as? [String: Any] {
            let (tap, hold, dbl) = Mapping.parseBindings(b)
            parsed.append(Profile(name: "default", bindings: tap, hold: hold, double: dbl))   // legacy flat
        }
        guard !parsed.isEmpty else { return }

        let spin = (obj["knobSpinRepeat"] as? Bool) ?? false
        let maxRep = (obj["knobMaxRepeat"] as? Int) ?? 4
        let holdMsRaw = (obj["holdMs"] as? Int) ?? 350
        let doubleMsRaw = (obj["doubleTapMs"] as? Int) ?? 250

        withLock {
            _knobSpinRepeat = spin
            _knobMaxRepeat = max(1, min(maxRep, 20))
            _holdMs = max(150, min(holdMsRaw, 1000))
            _doubleMs = max(120, min(doubleMsRaw, 600))
            let prevName = profiles.isEmpty ? "default" : profiles[safeActiveIndexLocked()].name
            // The default profile keeps the built-in defaults as a base, with the
            // file's values merged over it (so a partial/hand-edited file still has
            // every key). Other profiles are taken as written.
            var rebuilt: [Profile] = []
            var def = Profile(name: "default", bindings: Mapping.defaultsDict())
            if let fileDef = parsed.first(where: { $0.name == "default" }) {
                for (n, c) in fileDef.bindings { def.bindings[n] = c }
                def.hold = fileDef.hold
                def.double = fileDef.double
            }
            rebuilt.append(def)
            for p in parsed where p.name != "default" { rebuilt.append(p) }
            profiles = rebuilt
            _activeIndex = profiles.firstIndex { $0.name == prevName } ?? 0   // keep the active profile if it survived
        }
    }

    /// Split a raw bindings dict (values are strings or `{tap,hold?,double?}` objects) into
    /// the three per-action dicts. Empty hold/double are dropped so the dicts stay sparse.
    private static func parseBindings(_ raw: [String: Any]) -> (tap: [String: String], hold: [String: String], double: [String: String]) {
        var tap: [String: String] = [:], hold: [String: String] = [:], double: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String {
                tap[k] = s
            } else if let o = v as? [String: Any] {
                tap[k] = (o["tap"] as? String) ?? ""
                if let h = o["hold"] as? String, !h.isEmpty { hold[k] = h }
                if let d = o["double"] as? String, !d.isEmpty { double[k] = d }
            }
        }
        return (tap, hold, double)
    }

    /// Write all profiles to the JSON file, in physical-layout order, with the
    /// explanatory note. Hand-rolled rather than JSONSerialization so the file stays
    /// human-friendly (stable order + the `_note`).
    private func persist() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let snap = withLock { profiles }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        func block(_ p: Profile) -> String {
            let head = "    {\n      \"name\": \"\(esc(p.name))\""
            var lines: [String] = []
            for name in Mapping.order {
                let tap = p.bindings[name] ?? ""
                let hold = p.hold[name] ?? ""
                let dbl = p.double[name] ?? ""
                if hold.isEmpty && dbl.isEmpty {
                    lines.append("        \"\(name)\": \"\(esc(tap))\"")     // plain key → string
                } else {
                    var parts = ["\"tap\": \"\(esc(tap))\""]                 // key with extras → object
                    if !hold.isEmpty { parts.append("\"hold\": \"\(esc(hold))\"") }
                    if !dbl.isEmpty { parts.append("\"double\": \"\(esc(dbl))\"") }
                    lines.append("        \"\(name)\": { \(parts.joined(separator: ", ")) }")
                }
            }
            return head + ",\n      \"bindings\": {\n" + lines.joined(separator: ",\n") + "\n      }\n    }"
        }
        let body = snap.map(block).joined(separator: ",\n")
        let (spin, maxRep, holdMsV, doubleMsV) = withLock { (_knobSpinRepeat, _knobMaxRepeat, _holdMs, _doubleMs) }
        let json = """
        {
          "_note": "\(esc(Mapping.configNote))",
          "knobSpinRepeat": \(spin ? "true" : "false"),
          "knobMaxRepeat": \(maxRep),
          "holdMs": \(holdMsV),
          "doubleTapMs": \(doubleMsV),
          "profiles": [
        \(body)
          ]
        }
        """
        withLock { lastWrittenJSON = json }
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Ensure exactly one `default` profile exists and sits at index 0. Lock held.
    private func ensureDefaultFirstLocked() {
        if let i = profiles.firstIndex(where: { $0.name == "default" }) {
            if i != 0 { let d = profiles.remove(at: i); profiles.insert(d, at: 0) }
        } else {
            profiles.insert(Profile(name: "default", bindings: Mapping.defaultsDict()), at: 0)
        }
    }

    // MARK: - Profile read/write API for the Settings window

    /// Profile names, default first.
    func profileNames() -> [String] {
        withLock { profiles.map { $0.name } }
    }

    /// One profile's tap bindings in physical-layout order (missing keys yield "").
    func bindings(forProfile name: String) -> [(name: String, cmd: String)] {
        let snap = withLock { profiles.first(where: { $0.name == name })?.bindings ?? [:] }
        return Mapping.order.map { ($0, snap[$0] ?? "") }
    }

    /// One profile's full bindings (tap + hold + double) as sparse dicts — for the Settings
    /// window's working copy and export.
    func keyBindings(forProfile name: String) -> ProfileBindings {
        withLock {
            let p = profiles.first(where: { $0.name == name })
            return ProfileBindings(name: name, tap: p?.bindings ?? [:],
                                   hold: p?.hold ?? [:], double: p?.double ?? [:])
        }
    }

    /// Replace the entire profile set in one shot (one disk write), then apply live.
    /// String form: tap commands only — clears any hold/double on these profiles.
    func replaceAllProfiles(_ list: [(name: String, bindings: [String: String])]) {
        replaceAll(list.map { Profile(name: $0.name, bindings: $0.bindings) })
    }

    /// Full form (tap + hold + double). Used by the Settings window's Save so multiple
    /// profiles can't race the watcher and the secondary actions are preserved.
    func replaceAllProfiles(_ list: [ProfileBindings]) {
        replaceAll(list.map { Profile(name: $0.name, bindings: $0.tap, hold: $0.hold, double: $0.double) })
    }

    private func replaceAll(_ built: [Profile]) {
        let newName: String = withLock {
            let prevName = profiles.isEmpty ? "default" : profiles[safeActiveIndexLocked()].name
            profiles = built
            ensureDefaultFirstLocked()
            _activeIndex = profiles.firstIndex { $0.name == prevName } ?? 0   // keep active profile if it survived
            return profiles[_activeIndex].name
        }
        persist()
        onActiveProfileChange?(newName)
    }

    /// Add a profile, seeded as a copy of the default profile (all three actions). No-op if
    /// the name is empty/"default"/already taken. Persists + applies live.
    @discardableResult
    func addProfile(named name: String) -> Bool {
        let ok: Bool = withLock {
            guard !name.isEmpty, name != "default",
                  !profiles.contains(where: { $0.name == name }) else { return false }
            let seed = profiles[0]
            profiles.append(Profile(name: name, bindings: seed.bindings, hold: seed.hold, double: seed.double))
            return true
        }
        if ok { persist() }
        return ok
    }

    /// Remove a profile by name (the `default` profile cannot be removed).
    func removeProfile(_ name: String) {
        guard name != "default" else { return }
        let removed: Bool = withLock {
            let before = profiles.count
            profiles.removeAll { $0.name == name }
            return profiles.count != before
        }
        if removed { persist() }
    }

    // MARK: - Default-profile convenience (back-compat / tests)

    /// The default profile's bindings in physical-layout order.
    func current() -> [(name: String, cmd: String)] { bindings(forProfile: "default") }

    /// Merge into the default profile, persist, and apply live.
    func update(_ newBindings: [String: String]) {
        withLock { for (name, cmd) in newBindings { profiles[0].bindings[name] = cmd } }
        persist()
    }

    /// Restore the default profile to its built-in bindings (clearing hold/double),
    /// persist, apply live.
    func resetToDefaults() {
        withLock {
            profiles[0].bindings = Mapping.defaultsDict()
            profiles[0].hold = [:]
            profiles[0].double = [:]
        }
        persist()
    }

    // MARK: - Dispatch

    /// Run the command the active profile binds to the control whose raw HID id is `rawID`.
    /// This is the simple **tap** path (keyboard/consumer keyDown, knob press); the hold /
    /// double-tap gestures come through `dispatchGesture` from the gesture engine.
    func dispatch(_ rawID: String) {
        guard let name = idToName[rawID] else { return }
        // The profile-switch control is reserved app-wide: it cycles profiles and
        // never runs a bound command. In Listen mode it still reports so an open
        // Settings window can locate it.
        if name == Mapping.profileSwitchControl {
            if identifyMode { onControl?(name, nil, false) } else { cycleProfile() }
            return
        }
        run(name: name, command: activeBinding(for: name))
    }

    /// Run the command for a resolved key gesture (tap / hold / double-tap). The gesture
    /// engine only emits `.hold` / `.double` for keys that actually define them, so each
    /// gesture runs its own command verbatim (no falling back across gestures).
    func dispatchGesture(name: String, gesture: KeyGesture) {
        let cmd: String?
        switch gesture {
        case .tap:    cmd = activeBinding(for: name)
        case .hold:   cmd = activeHold(for: name)
        case .double: cmd = activeDouble(for: name)
        }
        run(name: name, command: cmd)
    }

    /// Run a knob turn. Always exposes `$KD100_DELTA` / `$KD100_VELOCITY` to the command;
    /// when spin-to-repeat is on, a multi-detent report runs the command that many times
    /// (capped) so a fast flick covers several steps. See `knobSpinRepeat`.
    func dispatchKnobTurn(cw: Bool, delta: Int, velocity: Int) {
        let name = cw ? "knob-cw" : "knob-ccw"
        let (spin, maxRep) = withLock { (_knobSpinRepeat, _knobMaxRepeat) }
        let count = spin ? min(max(1, delta), maxRep) : 1
        let env = ["KD100_DELTA": String(delta), "KD100_VELOCITY": String(velocity)]
        run(name: name, command: activeBinding(for: name), env: env, repeatCount: count)
    }

    /// Report a control via `onControl` and run `command` (unless in identify/Listen mode or
    /// it's blank). `repeatCount > 1` runs the command that many times **in one shell**
    /// (`cmd ; cmd ; …`) so the steps stay ordered.
    private func run(name: String, command: String?, env: [String: String]? = nil, repeatCount: Int = 1) {
        // A profile action (@cycle / @profile / @toggle) switches profiles instead of
        // spawning a shell — this is how a key becomes a "layer" toggle.
        if let cmd = command, let action = Mapping.parseAction(cmd) {
            onControl?(name, cmd, !identifyMode)
            if !identifyMode { perform(action) }
            return
        }
        let willRun = !identifyMode && (command?.isEmpty == false)
        onControl?(name, command, willRun)
        guard willRun, let cmd = command else { return }
        let toRun = repeatCount > 1
            ? Array(repeating: cmd, count: repeatCount).joined(separator: " ; ")
            : cmd
        execute(name: name, cmd: toRun, env: env, completion: nil)
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
    private func execute(name: String, cmd: String, env: [String: String]? = nil,
                         completion: ((Int32, String) -> Void)?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", cmd]
        p.standardOutput = FileHandle.nullDevice
        if let env {   // merge over the inherited environment so PATH/tools survive
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }

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
