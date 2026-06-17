import AppKit

/// A faithful, scaled render of the Huion KD100: a matte body, a metallic top band
/// holding the rotary dial (top-left) and the active-profile name, then the 18 keycaps
/// in the device's true geometry — the split `+` (two caps, col 4 of rows 2–3), the
/// **tall `Enter`** (col 4, rows 4–5), and the **wide `0`** (cols 1–2, row 5) — each
/// labelled with its live binding, plus a knob legend along the bottom.
///
/// Static render for the HUD cheat-sheet; the same view is also the interactive map in
/// the Settings window (`onSelect` + `flash` + a selection highlight), so there is one
/// device render across the app.
final class DeviceView: NSView {
    /// (key name, col, row, column-span, row-span) in the 4-wide grid. The three knob
    /// controls are drawn in the legend, not as caps.
    static let cells: [(name: String, col: Int, row: Int, cspan: Int, rspan: Int)] = [
        ("numlock", 0, 0, 1, 1), ("slash", 1, 0, 1, 1), ("star", 2, 0, 1, 1), ("minus", 3, 0, 1, 1),
        ("7", 0, 1, 1, 1), ("8", 1, 1, 1, 1), ("9", 2, 1, 1, 1), ("plus-upper", 3, 1, 1, 1),
        ("4", 0, 2, 1, 1), ("5", 1, 2, 1, 1), ("6", 2, 2, 1, 1), ("plus-lower", 3, 2, 1, 1),
        ("1", 0, 3, 1, 1), ("2", 1, 3, 1, 1), ("3", 2, 3, 1, 1), ("enter", 3, 3, 1, 2),
        ("0", 0, 4, 2, 1), ("dot", 2, 4, 1, 1),
    ]

    private let capW: CGFloat = 54, capH: CGFloat = 44, gap: CGFloat = 8
    private let bandH: CGFloat = 54
    private var gridW: CGFloat { 4 * capW + 3 * gap }                 // 240
    private var keysTop: CGFloat { bandH + 14 }                       // 68
    private var legendTop: CGFloat { keysTop + 5 * capH + 4 * gap + 12 }

    /// Natural size of the rendered device (callers pad around it).
    static let preferredSize = NSSize(width: 240, height: 54 + 14 + 5 * 44 + 4 * 8 + 12 + 18)

    private var profile: String
    private var tint: NSColor
    private var bindings: [String: String]
    private var selected: String?
    private var flashed: String?

    /// Click a keycap → its name. Set by the Settings window to focus the matching field.
    var onSelect: ((String) -> Void)?

    init(profile: String, tint: NSColor, bindings: [String: String]) {
        self.profile = profile
        self.tint = tint
        self.bindings = bindings
        super.init(frame: NSRect(origin: .zero, size: DeviceView.preferredSize))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }   // top-left origin for natural top-to-bottom layout

    // MARK: - State

    func update(profile: String, tint: NSColor, bindings: [String: String]) {
        self.profile = profile; self.tint = tint; self.bindings = bindings
        needsDisplay = true
    }

    /// Live-edit a single cap's label (Settings reflects typing as you go).
    func updateBinding(_ name: String, _ cmd: String) {
        bindings[name] = cmd
        needsDisplay = true
    }

    func select(_ name: String?) { selected = name; needsDisplay = true }

    /// Briefly highlight a cap to acknowledge a physical press (Listen mode).
    func flash(_ name: String) {
        guard DeviceView.cells.contains(where: { $0.name == name }) else { return }
        flashed = name; needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            if self?.flashed == name { self?.flashed = nil; self?.needsDisplay = true }
        }
    }

    // MARK: - Geometry

    private func colX(_ c: Int) -> CGFloat { CGFloat(c) * (capW + gap) }
    private func rowY(_ r: Int) -> CGFloat { keysTop + CGFloat(r) * (capH + gap) }

    private func capRect(col: Int, row: Int, cspan: Int, rspan: Int) -> NSRect {
        let w = CGFloat(cspan) * capW + CGFloat(cspan - 1) * gap
        let h = CGFloat(rspan) * capH + CGFloat(rspan - 1) * gap
        return NSRect(x: colX(col), y: rowY(row), width: w, height: h)
    }

    private lazy var capFrames: [(name: String, rect: NSRect)] = DeviceView.cells.map {
        ($0.name, capRect(col: $0.col, row: $0.row, cspan: $0.cspan, rspan: $0.rspan))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = capFrames.first(where: { $0.rect.contains(p) }) else { return }
        select(hit.name)
        onSelect?(hit.name)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bodyPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        Theme.body.setFill(); bodyPath.fill()
        Theme.bodyRim.setStroke(); bodyPath.lineWidth = 1; bodyPath.stroke()

        NSGraphicsContext.saveGraphicsState()
        bodyPath.addClip()
        let band = NSRect(x: 0, y: 0, width: gridW, height: bandH)
        NSGradient(starting: Theme.bandHi, ending: Theme.bandLo)?.draw(in: band, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        drawDial(center: NSPoint(x: 36, y: bandH / 2), radius: 19)
        drawProfileName(in: band)

        for f in capFrames { drawCap(name: f.name, in: f.rect) }
        drawLegend()
    }

    private func drawDial(center: NSPoint, radius r: CGFloat) {
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        NSGradient(colors: [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.64, alpha: 1)])?
            .draw(in: outer, relativeCenterPosition: NSPoint(x: -0.25, y: 0.35))
        NSColor(white: 0.45, alpha: 1).setStroke(); outer.lineWidth = 1; outer.stroke()
        let ir = r * 0.52
        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - ir, y: center.y - ir, width: 2 * ir, height: 2 * ir))
        NSColor(white: 0.82, alpha: 1).setFill(); inner.fill()
        NSColor(white: 0.52, alpha: 1).setStroke(); inner.lineWidth = 1; inner.stroke()
    }

    private func drawProfileName(in band: NSRect) {
        let rightPad: CGFloat = 14
        let cap = "kd100" as NSString
        let capAttr: [NSAttributedString.Key: Any] = [
            .font: Theme.ui(10, .bold), .foregroundColor: NSColor(white: 0.32, alpha: 1),
        ]
        let onMetal = tint.blended(withFraction: 0.45, of: .black) ?? tint
        let name = profile as NSString
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: Theme.ui(15, .heavy), .foregroundColor: onMetal,
        ]
        let capSize = cap.size(withAttributes: capAttr)
        let nameSize = name.size(withAttributes: nameAttr)
        cap.draw(at: NSPoint(x: band.maxX - rightPad - capSize.width, y: band.midY - 18), withAttributes: capAttr)
        name.draw(at: NSPoint(x: band.maxX - rightPad - nameSize.width, y: band.midY - 2), withAttributes: nameAttr)
    }

    private func drawCap(name: String, in r: NSRect) {
        let cmd = bindings[name] ?? ""
        let disabled = cmd.isEmpty
        let isFlash = (flashed == name)
        let isSel = (selected == name)

        let path = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                                xRadius: Theme.keycapRadius, yRadius: Theme.keycapRadius)
        if isFlash {
            tint.setFill()
        } else {
            (disabled ? Theme.keycap.withAlphaComponent(0.5) : Theme.keycap).setFill()
        }
        path.fill()
        if isSel {
            tint.setStroke(); path.lineWidth = 2
        } else {
            Theme.keycapEdge.withAlphaComponent(disabled && !isFlash ? 0.3 : 1).setStroke(); path.lineWidth = 1
        }
        path.stroke()

        let glyphAttr: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9, .semibold),
            .foregroundColor: isFlash ? NSColor.black.withAlphaComponent(0.65) : Theme.keyFaint,
        ]
        (Theme.keyGlyph(name) as NSString).draw(at: NSPoint(x: r.minX + 7, y: r.minY + 5), withAttributes: glyphAttr)

        let label = Theme.prettyBinding(cmd)
        guard !label.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attr: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9, .medium),
            .foregroundColor: isFlash ? NSColor.black.withAlphaComponent(0.85) : Theme.keyText,
            .paragraphStyle: para,
        ]
        let textRect = NSRect(x: r.minX + 4, y: r.minY + r.height / 2 - 8, width: r.width - 8, height: r.height / 2)
        (label as NSString).draw(in: textRect, withAttributes: attr)
    }

    private func drawLegend() {
        let ccw = Theme.prettyBinding(bindings["knob-ccw"] ?? "")
        let cw = Theme.prettyBinding(bindings["knob-cw"] ?? "")
        let line = "⟲ \(ccw.isEmpty ? "—" : ccw)     ⟳ \(cw.isEmpty ? "—" : cw)     ⏺ switch profile"
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attr: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9, .medium), .foregroundColor: Theme.keyFaint, .paragraphStyle: para,
        ]
        (line as NSString).draw(in: NSRect(x: 4, y: legendTop, width: gridW - 8, height: 16), withAttributes: attr)
    }
}
