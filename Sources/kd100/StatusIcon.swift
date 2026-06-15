import AppKit

/// The menu-bar (status-bar) icon. A dial best evokes the KD100's defining
/// feature (the rotary knob), so we use the `dial.*` SF Symbol when present and
/// fall back through a couple of alternatives, finally drawing a tiny dial by
/// hand so the icon is never missing on older systems.
enum StatusIcon {
    static func menuBarImage() -> NSImage {
        let candidates = ["dial.medium.fill", "dial.medium", "dial.min", "circle.dotted"]
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        for name in candidates {
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "KD100")?
                .withSymbolConfiguration(config) {
                symbol.isTemplate = true
                return symbol
            }
        }
        return drawnDial()
    }

    /// Hand-drawn fallback: a ringed dial with a pointer tick at 12 o'clock.
    private static func drawnDial() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.6
            NSColor.black.setStroke()
            ring.stroke()

            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: rect.midX, y: rect.midY + 1.5))
            tick.line(to: NSPoint(x: rect.midX, y: rect.maxY - 3.5))
            tick.lineWidth = 1.6
            NSColor.black.setStroke()
            tick.stroke()
            return true
        }
        image.isTemplate = true   // adapts to light/dark menu bar
        return image
    }
}
