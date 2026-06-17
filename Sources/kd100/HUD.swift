import AppKit

/// The on-screen overlay: a floating, non-activating vibrant card that never steals
/// focus from whatever you're working in. Two jobs:
///  - `flash(profile:)` — a quick chip naming the active profile on every knob-press
///    switch (the thing you lost when you hid the menu bar). Auto-fades.
///  - `reveal(profile:bindings:)` — the full device cheat-sheet, on demand (⌥⌘K, the
///    menu item, or the sketchybar pill). Stays until toggled off or you click away.
final class HUDController {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var clickMonitor: Any?
    private(set) var isRevealed = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // MARK: - Flash (profile-switch confirmation)

    func flash(profile: String) {
        let chip = makeChip(profile: profile, tint: Theme.tint(for: profile))
        present(content: chip, interactive: false)
        isRevealed = false
        removeClickAwayMonitor()
        scheduleHide(after: 1.3)
    }

    // MARK: - Reveal (cheat-sheet)

    func reveal(profile: String, bindings: [String: String], secondary: Set<String> = []) {
        let device = DeviceView(profile: profile, tint: Theme.tint(for: profile),
                                bindings: bindings, secondary: secondary)
        present(content: device, interactive: true)
        isRevealed = true
        installClickAwayMonitor()
    }

    func toggleReveal(profile: String, bindings: [String: String], secondary: Set<String> = []) {
        if isRevealed && panel.isVisible {
            dismiss()
        } else {
            reveal(profile: profile, bindings: bindings, secondary: secondary)
        }
    }

    func dismiss() {
        hideWork?.cancel(); hideWork = nil
        removeClickAwayMonitor()
        isRevealed = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in panel?.orderOut(nil) })
    }

    // MARK: - Internals

    private func present(content: NSView, interactive: Bool) {
        hideWork?.cancel(); hideWork = nil
        let pad = Theme.pad
        let size = NSSize(width: content.frame.width + pad * 2, height: content.frame.height + pad * 2)
        let card = Theme.card(NSRect(origin: .zero, size: size))
        content.setFrameOrigin(NSPoint(x: pad, y: pad))
        card.addSubview(content)
        panel.contentView = card
        panel.setContentSize(size)
        panel.ignoresMouseEvents = !interactive

        positionPanel()
        let finalFrame = panel.frame
        var start = finalFrame; start.origin.y -= 10          // rise into place
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2, y: vf.minY + vf.height * 0.16))
    }

    private func scheduleHide(after t: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    private func installClickAwayMonitor() {
        removeClickAwayMonitor()
        // A click anywhere outside our app dismisses the cheat-sheet.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeClickAwayMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    /// Compact chip for the profile-switch flash: dial glyph + profile name in the
    /// profile tint, on the dark vibrant card.
    private func makeChip(profile: String, tint: NSColor) -> NSView {
        let h: CGFloat = 68
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: h))

        let dial = NSImageView(frame: NSRect(x: 16, y: h / 2 - 19, width: 38, height: 38))
        let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        dial.image = NSImage(systemSymbolName: "dial.medium.fill", accessibilityDescription: "kd100")?
            .withSymbolConfiguration(cfg)
        dial.contentTintColor = tint
        dial.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(dial)

        let label = NSTextField(labelWithString: profile)
        label.font = Theme.ui(22, .semibold)
        label.textColor = tint
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 62, y: h / 2 - label.frame.height / 2)
        v.addSubview(label)

        v.frame.size.width = max(200, 62 + label.frame.width + 24)
        return v
    }
}
