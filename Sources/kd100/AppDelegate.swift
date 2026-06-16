import AppKit
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Menu-bar (tray) app. Owns the KD100 engine in `run` mode, shows live
/// connection status, opens the Settings window, and offers Open-at-Login + Quit.
/// No dock icon — the app runs as an accessory (LSUIElement / .accessory policy).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = KD100(mode: .run)
    private var settings: SettingsWindowController?

    // Menu items kept around so callbacks can mutate their titles/state.
    private var statusLine: NSMenuItem!
    private var lastFireLine: NSMenuItem!
    private var profileLine: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.menuBarImage()
        statusItem.button?.toolTip = "KD100 — Keydial controller"
        statusItem.menu = buildMenu()

        wireEngine()
        engine.start()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusLine = disabledItem("Starting…")
        menu.addItem(statusLine)
        lastFireLine = disabledItem("No input yet")
        menu.addItem(lastFireLine)

        profileLine = disabledItem("Profile: default")
        profileLine.isHidden = true   // only shown once an app-specific profile exists
        menu.addItem(profileLine)

        permissionItem = NSMenuItem(title: "Open Input Monitoring settings…",
                                    action: #selector(openInputMonitoring), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        refreshLoginState()

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit KD100", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Engine wiring

    private func wireEngine() {
        engine.onHealth = { [weak self] health in
            DispatchQueue.main.async { self?.apply(health) }
        }
        engine.mapping.onControl = { [weak self] name, cmd, executed in
            DispatchQueue.main.async {
                self?.settings?.controlFired(name)   // flash the key in an open Settings window
                if executed {
                    self?.lastFireLine.title = "Last: \(name) → \(cmd ?? "")"
                } else if (cmd?.isEmpty ?? true) {
                    self?.lastFireLine.title = "Last: \(name) (unmapped)"
                }
                // identify mode with a mapped command: leave the menu line as-is.
            }
        }
        engine.mapping.onResult = { [weak self] name, code, tail in
            guard code != 0 else { return }   // only surface failures
            DispatchQueue.main.async {
                let short = tail.split(separator: "\n").last.map(String.init) ?? ""
                self?.lastFireLine.title = "Last: \(name) → failed (\(code))"
                    + (short.isEmpty ? "" : ": \(short)")
                NSLog("KD100: '\(name)' exited \(code)\(tail.isEmpty ? "" : ": \(tail)")")
            }
        }
        engine.mapping.onExternalChange = { [weak self] in
            self?.settings?.reloadFromMapping()   // load() also re-fires onActiveProfileChange
        }
        engine.mapping.onActiveProfileChange = { [weak self] name in
            DispatchQueue.main.async { self?.updateProfileLine(name) }
        }
        engine.mapping.startWatching()
        updateProfileLine(engine.mapping.activeProfileName)
    }

    // MARK: - Active profile indicator

    /// Reflect the manually-selected active profile: a menu line, and — when not the
    /// default — the profile name next to the menu-bar dial icon. The knob press
    /// cycles profiles (Mapping reserves that control), which drives this callback.
    private func updateProfileLine(_ name: String) {
        let multi = engine.mapping.profileSummaries().count > 1
        profileLine.isHidden = !multi
        profileLine.title = "Profile: \(name)"
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.title = (name == "default") ? "" : " \(name)"
        }
    }

    private func apply(_ health: KD100.Health) {
        permissionItem.isHidden = true
        switch health {
        case .connected:       statusLine.title = "● Keypad connected"
        case .waiting:         statusLine.title = "○ Waiting for keypad…"
        case .needsPermission:
            statusLine.title = "⚠ Input Monitoring not granted"
            permissionItem.isHidden = false
        case .busy:            statusLine.title = "⚠ Device busy (Karabiner?)"
        case .error(let code): statusLine.title = "⚠ Open failed \(code)"
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(mapping: engine.mapping)
            settings?.onProfilesChanged = { [weak self] in
                guard let self else { return }
                self.updateProfileLine(self.engine.mapping.activeProfileName)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Open at Login (macOS 13+)

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("KD100: Open-at-Login toggle failed: \(error.localizedDescription)")
            }
            refreshLoginState()
        }
    }

    private func refreshLoginState() {
        if #available(macOS 13.0, *) {
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            loginItem.isHidden = false
        } else {
            loginItem.isHidden = true   // pre-13 has no clean SMAppService path
        }
    }
}
