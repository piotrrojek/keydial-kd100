import AppKit

/// Shared visual language for kd100's on-screen surfaces (the HUD now; the Settings
/// window in a later phase). One place for color, type, metrics, and the small helpers
/// every surface needs — so the app reads as one designed thing rather than a pile of
/// default controls.
enum Theme {
    // MARK: - Color

    /// Profile tints mirror the sketchybar pill (Catppuccin Frappé) so the bar and the
    /// HUD feel like one system: lavender = default, peach = any non-default profile.
    static let lavender = NSColor(srgbRed: 0xBA / 255.0, green: 0xBB / 255.0, blue: 0xF1 / 255.0, alpha: 1)
    static let peach    = NSColor(srgbRed: 0xEF / 255.0, green: 0x9F / 255.0, blue: 0x76 / 255.0, alpha: 1)
    static func tint(for profile: String) -> NSColor { profile == "default" ? lavender : peach }

    /// The rendered device.
    static let body       = NSColor(white: 0.11, alpha: 1)   // matte black shell
    static let bodyRim    = NSColor(white: 0.30, alpha: 1)   // hairline edge highlight
    static let keycap     = NSColor(white: 0.17, alpha: 1)
    static let keycapEdge = NSColor(white: 0.27, alpha: 1)   // top bevel
    static let keyText    = NSColor(white: 0.95, alpha: 1)
    static let keyFaint   = NSColor(white: 0.55, alpha: 1)
    static let bandHi     = NSColor(white: 0.84, alpha: 1)   // metallic band gradient
    static let bandLo     = NSColor(white: 0.60, alpha: 1)

    // MARK: - Metrics (8pt grid)

    static let unit: CGFloat = 8
    static let panelRadius: CGFloat = 18
    static let keycapRadius: CGFloat = 9
    static let pad: CGFloat = 18

    // MARK: - Type

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Helpers

    /// A dark, rounded, vibrant card used as the HUD background.
    static func card(_ frame: NSRect) -> NSVisualEffectView {
        let v = NSVisualEffectView(frame: frame)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = panelRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        return v
    }

    /// Short cap glyph for a physical key name (the spatial position already says which
    /// key it is, so this is just a faint corner tag).
    static func keyGlyph(_ name: String) -> String {
        switch name {
        case "slash": return "/"
        case "star": return "∗"
        case "minus": return "−"
        case "plus-upper", "plus-lower": return "+"
        case "dot": return "."
        case "enter": return "⏎"
        case "numlock": return "num"
        default: return name   // digits
        }
    }

    /// Turn a bound shell command into a short, legible action label for a keycap:
    /// strip the kd100 scripts-dir prefix, surrounding quotes, and the `aerospace` verb
    /// so the meaningful part survives the small space. "" stays empty (a disabled key).
    static func prettyBinding(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: "\"", with: "")
        for p in ["$HOME/.config/kd100/scripts/", "~/.config/kd100/scripts/"] {
            s = s.replacingOccurrences(of: p, with: "")
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            s = s.replacingOccurrences(of: home, with: "~")
        }
        if s.hasPrefix("aerospace ") { s = String(s.dropFirst("aerospace ".count)) }
        return s
    }
}
