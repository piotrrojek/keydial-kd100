import XCTest
import AppKit
import Carbon.HIToolbox
@testable import kd100

/// Tests the cheat-sheet hotkey preference: defaulting, UserDefaults round-trip, and the
/// NSEvent → Carbon conversion the recorder relies on.
final class CheatSheetHotkeyTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "kd100-hotkey-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultWhenUnset() {
        let hk = CheatSheetHotkey.load(freshDefaults())
        XCTAssertEqual(hk, .default)
        XCTAssertEqual(hk.display, "⌥⌘K")
        XCTAssertEqual(hk.keyCode, UInt32(kVK_ANSI_K))
    }

    func testSaveLoadRoundTrip() {
        let d = freshDefaults()
        let hk = CheatSheetHotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | cmdKey), display: "⌃⌘J")
        hk.save(d)
        XCTAssertEqual(CheatSheetHotkey.load(d), hk)
    }

    func testFromEventRequiresAModifier() {
        let bare = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "k",
                                    charactersIgnoringModifiers: "k", isARepeat: false,
                                    keyCode: UInt16(kVK_ANSI_K))!
        XCTAssertNil(CheatSheetHotkey.from(event: bare))   // a bare key is rejected
    }

    func testFromEventBuildsCarbonMaskAndDisplay() {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                 timestamp: 0, windowNumber: 0, context: nil, characters: "k",
                                 charactersIgnoringModifiers: "k", isARepeat: false,
                                 keyCode: UInt16(kVK_ANSI_K))!
        let hk = CheatSheetHotkey.from(event: e)
        XCTAssertEqual(hk?.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(hk?.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(hk?.display, "⌥⌘K")
    }

    func testDisplayStringUsesConventionalOrder() {
        let s = CheatSheetHotkey.displayString(modifiers: [.shift, .command, .control, .option],
                                               keyCode: UInt32(kVK_ANSI_A), chars: "a")
        XCTAssertEqual(s, "⌃⌥⇧⌘A")
    }
}
