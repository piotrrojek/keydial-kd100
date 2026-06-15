import AppKit

/// Settings window: one editable command field per physical key + knob action.
/// Save writes `~/.config/kd100/mapping.json` and applies live (the engine shares
/// this same Mapping instance, so the next keypress uses the new bindings — no
/// restart). Leaving a field blank disables that key.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let mapping: Mapping
    private var fields: [String: NSTextField] = [:]
    private var savedLabel: NSTextField!

    init(mapping: Mapping) {
        self.mapping = mapping
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "KD100 — Key Mapping"
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Bottom action bar.
        let resetButton = makeButton("Reset to Defaults", #selector(resetTapped))
        let saveButton = makeButton("Save", #selector(saveTapped))
        saveButton.keyEquivalent = "\r"   // Return triggers Save
        saveButton.bezelStyle = .rounded

        savedLabel = NSTextField(labelWithString: "")
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.font = .systemFont(ofSize: 11)
        savedLabel.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [resetButton, savedLabel, NSView(), saveButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        // Scrollable form.
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
        form.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        form.addArrangedSubview(makeHelp(
            "Each key runs the command below via /bin/sh. Commands aren't limited to "
            + "aerospace — use open, osascript, scripts, anything. Leave a field blank to "
            + "disable that key. Changes apply immediately on Save."))

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
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),

            // Document tracks the scroll view's width so rows fill horizontally
            // and only vertical scrolling happens.
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            form.topAnchor.constraint(equalTo: document.topAnchor),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    /// A label + text field row. The label is fixed-width so all fields align.
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

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeSectionHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeHelp(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 520
        return label
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - Load / save

    private func reload() {
        for (name, cmd) in mapping.current() { fields[name]?.stringValue = cmd }
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
        // Repopulate fields from the built-in defaults; not persisted until Save.
        var defaults: [String: String] = [:]
        for (name, cmd) in Mapping.defaults { defaults[name] = cmd }
        for (name, field) in fields { field.stringValue = defaults[name] ?? "" }
        savedLabel.stringValue = "Defaults loaded — press Save to apply"
    }

    private func flashSaved() {
        savedLabel.stringValue = "Saved ✓"
        let token = savedLabel.stringValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.savedLabel.stringValue == token { self?.savedLabel.stringValue = "" }
        }
    }
}
