import AppKit
import Carbon.HIToolbox

/// The user's chosen global hotkey for toggling the cheat-sheet, persisted in
/// `UserDefaults` (an app preference, not part of the device mapping).
///
/// Stored as a Carbon **virtual key code** + Carbon **modifier mask** — exactly what
/// `RegisterEventHotKey` (see `GlobalHotKey`) wants — plus a pre-rendered display string
/// (e.g. `⌥⌘K`) for the menu and Settings. The default is ⌥⌘K, matching the original
/// fixed shortcut, so existing users see no change.
struct CheatSheetHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon mask: cmdKey | optionKey | controlKey | shiftKey
    var display: String

    static let `default` = CheatSheetHotkey(keyCode: UInt32(kVK_ANSI_K),
                                            modifiers: UInt32(cmdKey | optionKey),
                                            display: "⌥⌘K")

    private static let kCode = "cheatSheetKeyCode"
    private static let kMods = "cheatSheetModifiers"
    private static let kDisp = "cheatSheetDisplay"

    static func load(_ d: UserDefaults = .standard) -> CheatSheetHotkey {
        guard d.object(forKey: kCode) != nil else { return .default }
        let code = UInt32(d.integer(forKey: kCode))
        let mods = UInt32(d.integer(forKey: kMods))
        guard code != 0, mods != 0 else { return .default }
        return CheatSheetHotkey(keyCode: code, modifiers: mods,
                                display: d.string(forKey: kDisp) ?? CheatSheetHotkey.default.display)
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(Int(keyCode), forKey: Self.kCode)
        d.set(Int(modifiers), forKey: Self.kMods)
        d.set(display, forKey: Self.kDisp)
    }

    /// Build from a recorded `keyDown`. Returns nil when no real modifier is held (a bare
    /// key makes a hostile global hotkey), so the recorder keeps waiting.
    static func from(event: NSEvent) -> CheatSheetHotkey? {
        let f = event.modifierFlags
        var carbon: UInt32 = 0
        if f.contains(.command) { carbon |= UInt32(cmdKey) }
        if f.contains(.option)  { carbon |= UInt32(optionKey) }
        if f.contains(.control) { carbon |= UInt32(controlKey) }
        if f.contains(.shift)   { carbon |= UInt32(shiftKey) }
        guard carbon != 0 else { return nil }
        return CheatSheetHotkey(keyCode: UInt32(event.keyCode), modifiers: carbon,
                                display: displayString(modifiers: f, keyCode: UInt32(event.keyCode),
                                                       chars: event.charactersIgnoringModifiers))
    }

    /// `⌃⌥⇧⌘` + a key glyph, in the conventional macOS order.
    static func displayString(modifiers f: NSEvent.ModifierFlags, keyCode: UInt32, chars: String?) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyName(keyCode: keyCode, chars: chars)
    }

    private static func keyName(keyCode: UInt32, chars: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
            return "Key\(keyCode)"
        }
    }
}
