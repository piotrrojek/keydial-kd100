import AppKit

/// A single key in the visual keypad map. Layer-backed so it can flash when the
/// matching physical key is pressed; clicking it focuses that key's command field.
final class KeyCell: NSView {
    let name: String
    var onClick: (() -> Void)?
    private let title = NSTextField(labelWithString: "")

    init(name: String, label: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        title.stringValue = label
        title.alignment = .center
        title.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 88),
            heightAnchor.constraint(equalToConstant: 34),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        toolTip = name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func clicked() { onClick?() }

    /// Briefly highlight to acknowledge a physical press (press-to-identify).
    func flash() {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        title.textColor = .white
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            self?.title.textColor = .labelColor
        }
    }
}

/// Settings window: a visual device map up top (click a key to jump to it; turn on
/// Listen and press a key to locate it) over a scrollable list of one editable
/// command field per physical key + knob action, each with a ▶ test button.
///
/// Save writes `~/.config/kd100/mapping.json` and applies live (the engine shares
/// this same Mapping instance). Leaving a field blank disables that key.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let mapping: Mapping
    private var fields: [String: NSTextField] = [:]
    private var cells: [String: KeyCell] = [:]
    private var savedLabel: NSTextField!
    private var listenButton: NSButton!
    private var listenHint: NSTextField!
    private var listening = false

    init(mapping: Mapping) {
        self.mapping = mapping
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "KD100 — Key Mapping"
        window.minSize = NSSize(width: 520, height: 540)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Engine hooks (called from AppDelegate on the main queue)

    /// A physical control fired: flash its cell, and in Listen mode jump to its field.
    func controlFired(_ name: String) {
        cells[name]?.flash()
        if listening { focusField(name) }
    }

    /// The config changed on disk outside the app — refresh the fields.
    func reloadFromMapping() { reload() }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // --- Fixed top: help + device map + Listen toggle ---
        let help = makeHelp(
            "Each key runs the command below via your login shell ($SHELL -ilc), so it sees the "
            + "same PATH/tools a Terminal does. Commands aren't limited to aerospace — use open, "
            + "osascript, scripts, anything. Blank = disabled. ▶ tests a command now; Save applies "
            + "everything immediately.")

        let mapTitle = makeSectionHeader("Device map — click a key to edit it")
        let keypad = buildKeypadMap()

        listenButton = NSButton(checkboxWithTitle: "Listen — press a key on the pad to locate it (commands paused)",
                                target: self, action: #selector(toggleListen(_:)))
        listenButton.translatesAutoresizingMaskIntoConstraints = false
        listenHint = NSTextField(labelWithString: "")
        listenHint.font = .systemFont(ofSize: 11)
        listenHint.textColor = .secondaryLabelColor
        listenHint.translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView(views: [help, mapTitle, keypad, listenButton, listenHint])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.setCustomSpacing(12, after: keypad)
        content.addSubview(topStack)

        // --- Bottom action bar ---
        let resetButton = makeButton("Reset to Defaults", #selector(resetTapped))
        let saveButton = makeButton("Save", #selector(saveTapped))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        savedLabel = NSTextField(labelWithString: "")
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.font = .systemFont(ofSize: 11)
        savedLabel.lineBreakMode = .byTruncatingTail
        savedLabel.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [resetButton, savedLabel, NSView(), saveButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        // --- Scrollable form (the editable rows) ---
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        form.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        form.addArrangedSubview(makeSectionHeader("Keys"))
        for (name, _) in mapping.current() where !Mapping.knobNames.contains(name) {
            form.addArrangedSubview(makeRow(name))
        }
        form.addArrangedSubview(makeSectionHeader("Knob"))
        for name in Mapping.order where Mapping.knobNames.contains(name) {
            form.addArrangedSubview(makeRow(name))
        }

        let pathLabel = NSTextField(labelWithString: mapping.path)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        form.setCustomSpacing(16, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(pathLabel)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        scroll.documentView = document

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            topStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            form.topAnchor.constraint(equalTo: document.topAnchor),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        help.preferredMaxLayoutWidth = 540
    }

    /// The visual keypad: rows 4/4/4/4/2 then a centered knob trio.
    private func buildKeypadMap() -> NSView {
        let rows: [[String]] = [
            ["numlock", "slash", "star", "minus"],
            ["7", "8", "9", "plus-upper"],
            ["4", "5", "6", "plus-lower"],
            ["1", "2", "3", "enter"],
            ["0", "dot"],
        ]
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        for r in rows {
            var views: [NSView] = []
            for c in 0..<4 { views.append(c < r.count ? makeCell(r[c]) : NSView()) }
            grid.addRow(with: views)
        }

        let knob = NSGridView()
        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.columnSpacing = 6
        knob.addRow(with: ["knob-ccw", "knob-press", "knob-cw"].map { makeCell($0) })

        let stack = NSStackView(views: [grid, makeSectionHeader("Knob"), knob])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeCell(_ name: String) -> KeyCell {
        let cell = KeyCell(name: name, label: SettingsWindowController.cellLabel(name))
        cell.onClick = { [weak self] in self?.focusField(name) }
        cells[name] = cell
        return cell
    }

    /// Short glyph for the keypad map; the internal name is still the tooltip.
    static func cellLabel(_ name: String) -> String {
        switch name {
        case "slash": return "/"
        case "star": return "∗"
        case "minus": return "−"
        case "plus-upper": return "+ ↑"
        case "plus-lower": return "+ ↓"
        case "dot": return "."
        case "enter": return "⏎"
        case "numlock": return "num"
        case "knob-cw": return "knob ⟳"
        case "knob-ccw": return "knob ⟲"
        case "knob-press": return "knob ⏺"
        default: return name   // digits
        }
    }

    /// A label + text field + test button row. The label is fixed-width so fields align.
    private func makeRow(_ name: String) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.alignment = .right
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let field = NSTextField()
        field.placeholderString = "(disabled)"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fields[name] = field

        let test = NSButton(title: "▶", target: self, action: #selector(testTapped(_:)))
        test.bezelStyle = .rounded
        test.toolTip = "Run this command now"
        test.identifier = NSUserInterfaceItemIdentifier(name)
        test.translatesAutoresizingMaskIntoConstraints = false
        test.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, field, test])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeHelp(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 540
        return label
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func focusField(_ name: String) {
        guard let field = fields[name] else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
        field.scrollToVisible(field.bounds)
    }

    // MARK: - Actions

    @objc private func toggleListen(_ sender: NSButton) {
        listening = (sender.state == .on)
        mapping.identifyMode = listening
        listenHint.stringValue = listening
            ? "Listening — press a key on the pad; it will be located here and its command won't run."
            : ""
    }

    @objc private func testTapped(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let field = fields[name] else { return }
        let cmd = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { savedLabel.stringValue = "\(name): nothing to run"; return }
        savedLabel.stringValue = "testing \(name)…"
        mapping.test(name: name, command: cmd) { [weak self] code, tail in
            if code == 0 {
                self?.savedLabel.stringValue = "test \(name) → ok ✓"
            } else {
                let t = tail.split(separator: "\n").last.map(String.init) ?? ""
                self?.savedLabel.stringValue = "test \(name) → failed (\(code))"
                    + (t.isEmpty ? "" : ": \(t)")
            }
        }
    }

    @objc private func saveTapped() {
        var out: [String: String] = [:]
        for (name, field) in fields {
            out[name] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        mapping.update(out)
        flashSaved()
    }

    @objc private func resetTapped() {
        var defaults: [String: String] = [:]
        for (name, cmd) in Mapping.defaults { defaults[name] = cmd }
        for (name, field) in fields { field.stringValue = defaults[name] ?? "" }
        savedLabel.stringValue = "Defaults loaded — press Save to apply"
    }

    // MARK: - Load

    private func reload() {
        for (name, cmd) in mapping.current() { fields[name]?.stringValue = cmd }
    }

    private func flashSaved() {
        savedLabel.stringValue = "Saved ✓"
        let token = savedLabel.stringValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.savedLabel.stringValue == token { self?.savedLabel.stringValue = "" }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Leaving Listen on after close would silently keep commands paused.
        listening = false
        mapping.identifyMode = false
        listenButton?.state = .off
    }
}
