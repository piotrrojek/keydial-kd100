import XCTest
import AppKit
@testable import kd100

/// Smoke test for the Settings window: constructing the controller runs the entire
/// Auto-Layout/keypad-map build, which is the bulk of the new UI code. Catches
/// constraint crashes / nil unwraps without a device or a visible window.
final class SettingsSmokeTests: XCTestCase {
    private func makeMapping() -> Mapping {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kd100-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Mapping(path: dir.appendingPathComponent("mapping.json").path)
    }

    @MainActor
    func testWindowBuildsWithAllFieldsAndCells() {
        _ = NSApplication.shared   // a window needs an app instance
        let controller = SettingsWindowController(mapping: makeMapping())
        XCTAssertNotNil(controller.window)

        // Forcing layout exercises every constraint we added.
        controller.window?.layoutIfNeeded()

        // controlFired / reload must be safe to call (engine hooks).
        controller.controlFired("7")
        controller.controlFired("knob-cw")
        controller.reloadFromMapping()
    }

    func testCellLabelsAreCompact() {
        XCTAssertEqual(SettingsWindowController.cellLabel("slash"), "/")
        XCTAssertEqual(SettingsWindowController.cellLabel("knob-press"), "knob ⏺")
        XCTAssertEqual(SettingsWindowController.cellLabel("7"), "7")
    }
}
