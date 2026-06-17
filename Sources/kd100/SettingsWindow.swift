import AppKit
import UniformTypeIdentifiers

/// Settings window: the faithful device map up top (click a key to edit it; turn on
/// Listen and press a key to locate it) over a scrollable list of one editable command
/// field per physical key + knob action, each with a ▶ test button. The map reflects
/// the bindings live as you type, and follows the profile picker.
///
/// Save writes `~/.config/kd100/mapping.json` and applies live (the engine shares this
/// same Mapping instance). Leaving a field blank disables that key. Profiles can be
/// exported (one, or all) and imported from `.json` files.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let mapping: Mapping
    private var fields: [String: NSTextField] = [:]
    private var deviceView: DeviceView!
    private var savedLabel: NSTextField!
    private var listenButton: NSButton!
    private var listenHint: NSTextField!
    private var listening = false

    // Knob velocity / continuous-mode controls (global, not per-profile).
    private var spinCheckbox: NSButton!
    private var maxRepeatStepper: NSStepper!
    private var maxRepeatValue: NSTextField!
    private var maxRepeatRow: NSStackView!

    // Gesture timing controls (global): hold threshold + double-tap window.
    private var holdStepper: NSStepper!
    private var holdValue: NSTextField!
    private var doubleStepper: NSStepper!
    private var doubleValue: NSTextField!

    /// Called after the profile set is committed (Save), so the tray app can refresh
    /// the active-profile menu line.
    var onProfilesChanged: (() -> Void)?

    /// In-memory working copy of every profile. Edits live here until Save commits the
    /// whole set in one shot (`mapping.replaceAllProfiles`) — so switching the editor
    /// between profiles never loses or prematurely persists changes.
    private struct EditProfile {
        var name: String
        var bindings: [String: String]              // tap
        var hold: [String: String] = [:]            // long-press
        var double: [String: String] = [:]          // double-tap
    }
    private var workingProfiles: [EditProfile] = []
    private var gestureButtons: [String: NSButton] = [:]   // per-key "secondary actions" button
    private var editingIndex = 0
    private var profilePopup: NSPopUpButton!
    private var removeButton: NSButton!
    private var profileHint: NSTextField!

    init(mapping: Mapping) {
        self.mapping = mapping
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "KD100 — Key Mapping"
        window.minSize = NSSize(width: 520, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Engine hooks (called from AppDelegate on the main queue)

    /// A physical control fired: flash its cap on the map, and in Listen mode jump to
    /// its field.
    func controlFired(_ name: String) {
        deviceView.flash(name)
        if listening { focusField(name) }
    }

    /// The config changed on disk outside the app — refresh the fields.
    func reloadFromMapping() { reload() }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let help = makeHelp(
            "Each key runs the command below via your login shell ($SHELL -ilc), so it sees the "
            + "same PATH/tools a Terminal does — use aerospace, open, osascript, scripts, anything. "
            + "Click a key on the map to jump to it; the map updates as you type. Blank = disabled. "
            + "▶ tests a command now; Save applies everything immediately. Tip: a command of "
            + "“@toggle <profile>” turns a key into a layer toggle (also @profile <name> / @cycle).")

        let profileBar = buildProfileBar()
        profileHint = NSTextField(labelWithString: "")
        profileHint.font = .systemFont(ofSize: 11)
        profileHint.textColor = .secondaryLabelColor
        profileHint.lineBreakMode = .byTruncatingTail
        profileHint.translatesAutoresizingMaskIntoConstraints = false

        let mapTitle = makeSectionHeader("Device map — click a key to edit it")
        deviceView = DeviceView(profile: "default", tint: Theme.tint(for: "default"), bindings: [:])
        deviceView.translatesAutoresizingMaskIntoConstraints = false
        deviceView.onSelect = { [weak self] name in self?.focusField(name) }
        NSLayoutConstraint.activate([
            deviceView.widthAnchor.constraint(equalToConstant: DeviceView.preferredSize.width),
            deviceView.heightAnchor.constraint(equalToConstant: DeviceView.preferredSize.height),
        ])

        listenButton = NSButton(checkboxWithTitle: "Listen — press a key on the pad to locate it (commands paused)",
                                target: self, action: #selector(toggleListen(_:)))
        listenButton.translatesAutoresizingMaskIntoConstraints = false
        listenHint = NSTextField(labelWithString: "")
        listenHint.font = .systemFont(ofSize: 11)
        listenHint.textColor = .secondaryLabelColor
        listenHint.translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView(views: [help, profileBar, profileHint, mapTitle, deviceView, listenButton, listenHint])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.setCustomSpacing(12, after: profileHint)
        topStack.setCustomSpacing(12, after: deviceView)
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
        for name in Mapping.order where !Mapping.knobNames.contains(name) {
            form.addArrangedSubview(makeRow(name))
        }
        form.addArrangedSubview(makeSectionHeader("Knob"))
        for name in Mapping.order where Mapping.knobNames.contains(name) {
            form.addArrangedSubview(makeRow(name))
        }
        form.setCustomSpacing(14, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(makeKnobOptions())

        form.addArrangedSubview(makeSectionHeader("Gestures"))
        form.setCustomSpacing(8, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(makeGestureOptions())

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

    /// Profile row: [Profile: ▾] [Add Profile…] [Remove] … [Export ▾] [Import…].
    private func buildProfileBar() -> NSView {
        let label = NSTextField(labelWithString: "Profile:")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profilePopup.translatesAutoresizingMaskIntoConstraints = false

        let addButton = makeButton("Add Profile…", #selector(addProfileTapped))
        addButton.toolTip = "Create a named profile (a copy of default) you cycle to with the knob press"
        removeButton = makeButton("Remove", #selector(removeProfileTapped))
        removeButton.toolTip = "Delete the selected profile (the default profile can't be removed)"

        let exportPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        exportPopup.addItems(withTitles: ["Export", "This profile…", "All profiles…"])
        exportPopup.target = self
        exportPopup.action = #selector(exportSelected(_:))
        exportPopup.toolTip = "Save the selected profile, or all profiles, to a .json file"
        exportPopup.translatesAutoresizingMaskIntoConstraints = false

        let importButton = makeButton("Import…", #selector(importTapped))
        importButton.toolTip = "Add profiles from a .json file (kept as a working copy until you Save)"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [label, profilePopup, addButton, removeButton, spacer, exportPopup, importButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .firstBaseline
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    /// Short glyph for a key name (kept for compatibility / tests; the device map now
    /// renders the caps directly).
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

        // The profile-switch control is reserved app-wide — not editable per profile.
        if name == Mapping.profileSwitchControl {
            let note = NSTextField(labelWithString: "↻ cycles profiles (reserved)")
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [label, note])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        let field = NSTextField()
        field.placeholderString = "(disabled)"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.identifier = NSUserInterfaceItemIdentifier(name)   // so live edits map back to the key
        field.delegate = self
        fields[name] = field

        let test = NSButton(title: "▶", target: self, action: #selector(testTapped(_:)))
        test.bezelStyle = .rounded
        test.toolTip = "Run this command now"
        test.identifier = NSUserInterfaceItemIdentifier(name)
        test.translatesAutoresizingMaskIntoConstraints = false
        test.setContentHuggingPriority(.required, for: .horizontal)

        var views = [label, field, test]
        // Keycaps get a hold / double-tap editor; the knob turns (cw/ccw) have no
        // press/release, so no secondary gestures there.
        if !Mapping.knobNames.contains(name) {
            let gear = NSButton(title: "⋯", target: self, action: #selector(gestureTapped(_:)))
            gear.bezelStyle = .rounded
            gear.toolTip = "Add a hold (long-press) or double-tap action for this key"
            gear.identifier = NSUserInterfaceItemIdentifier(name)
            gear.translatesAutoresizingMaskIntoConstraints = false
            gear.setContentHuggingPriority(.required, for: .horizontal)
            gestureButtons[name] = gear
            views.append(gear)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The knob velocity / continuous-mode block: a "Spin to repeat" checkbox and a
    /// max-repeats stepper, plus a hint that the env vars are always available.
    private func makeKnobOptions() -> NSView {
        spinCheckbox = NSButton(checkboxWithTitle: "Spin to repeat — a fast turn runs the knob command several times",
                                target: self, action: #selector(spinToggled(_:)))
        spinCheckbox.translatesAutoresizingMaskIntoConstraints = false
        spinCheckbox.toolTip = "When on, one quick flick of the knob fires the command once per detent (capped below)."

        let maxLabel = NSTextField(labelWithString: "Max repeats:")
        maxLabel.font = .systemFont(ofSize: 12)
        maxLabel.translatesAutoresizingMaskIntoConstraints = false

        maxRepeatStepper = NSStepper()
        maxRepeatStepper.minValue = 1
        maxRepeatStepper.maxValue = 20
        maxRepeatStepper.increment = 1
        maxRepeatStepper.valueWraps = false
        maxRepeatStepper.target = self
        maxRepeatStepper.action = #selector(maxRepeatChanged(_:))
        maxRepeatStepper.translatesAutoresizingMaskIntoConstraints = false

        maxRepeatValue = NSTextField(labelWithString: "4")
        maxRepeatValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        maxRepeatValue.alignment = .right
        maxRepeatValue.translatesAutoresizingMaskIntoConstraints = false
        maxRepeatValue.widthAnchor.constraint(equalToConstant: 22).isActive = true

        maxRepeatRow = NSStackView(views: [maxLabel, maxRepeatValue, maxRepeatStepper])
        maxRepeatRow.orientation = .horizontal
        maxRepeatRow.spacing = 6
        maxRepeatRow.alignment = .centerY
        maxRepeatRow.translatesAutoresizingMaskIntoConstraints = false
        maxRepeatRow.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)

        let hint = NSTextField(wrappingLabelWithString:
            "knob-cw / knob-ccw commands always see $KD100_DELTA (this turn’s magnitude) and "
            + "$KD100_VELOCITY (smoothed detents/sec) — e.g. aerospace resize smart +$((10*KD100_DELTA)).")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [spinCheckbox, maxRepeatRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func spinToggled(_ sender: NSButton) {
        maxRepeatRow.isHidden = (sender.state != .on)
    }

    @objc private func maxRepeatChanged(_ sender: NSStepper) {
        maxRepeatValue.stringValue = String(sender.integerValue)
    }

    /// Reflect the live knob options into the controls (called from `reload`).
    private func syncKnobOptions() {
        spinCheckbox.state = mapping.knobSpinRepeat ? .on : .off
        maxRepeatStepper.integerValue = mapping.knobMaxRepeat
        maxRepeatValue.stringValue = String(mapping.knobMaxRepeat)
        maxRepeatRow.isHidden = !mapping.knobSpinRepeat
    }

    /// The global gesture-timing block: hold threshold + double-tap window steppers.
    private func makeGestureOptions() -> NSView {
        func stepperRow(_ title: String, value: Int, min: Double, max: Double,
                        action: Selector) -> (row: NSStackView, stepper: NSStepper, label: NSTextField) {
            let lbl = NSTextField(labelWithString: title)
            lbl.font = .systemFont(ofSize: 12)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: 130).isActive = true

            let val = NSTextField(labelWithString: String(value))
            val.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            val.alignment = .right
            val.translatesAutoresizingMaskIntoConstraints = false
            val.widthAnchor.constraint(equalToConstant: 40).isActive = true

            let unit = NSTextField(labelWithString: "ms")
            unit.font = .systemFont(ofSize: 12)
            unit.textColor = .secondaryLabelColor
            unit.translatesAutoresizingMaskIntoConstraints = false

            let st = NSStepper()
            st.minValue = min; st.maxValue = max; st.increment = 10; st.valueWraps = false
            st.integerValue = value
            st.target = self; st.action = action
            st.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView(views: [lbl, val, unit, st])
            row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            return (row, st, val)
        }

        let hold = stepperRow("Hold threshold:", value: mapping.holdMs, min: 150, max: 1000,
                              action: #selector(holdChanged(_:)))
        holdStepper = hold.stepper; holdValue = hold.label
        let dbl = stepperRow("Double-tap window:", value: mapping.doubleTapMs, min: 120, max: 600,
                             action: #selector(doubleChanged(_:)))
        doubleStepper = dbl.stepper; doubleValue = dbl.label

        let hint = NSTextField(wrappingLabelWithString:
            "Use the ⋯ button on a key to add a Hold (long-press) or Double-tap action. Hold fires "
            + "after the threshold; a Double must land within the window (which is also the small tap "
            + "delay a double-bound key pays). A key with neither has zero added latency.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [hold.row, dbl.row, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func holdChanged(_ s: NSStepper) { holdValue.stringValue = String(s.integerValue) }
    @objc private func doubleChanged(_ s: NSStepper) { doubleValue.stringValue = String(s.integerValue) }

    private func syncGestureOptions() {
        holdStepper.integerValue = mapping.holdMs
        holdValue.stringValue = String(mapping.holdMs)
        doubleStepper.integerValue = mapping.doubleTapMs
        doubleValue.stringValue = String(mapping.doubleTapMs)
    }

    /// Open the per-key secondary-action editor (Tap / Hold / Double) for a keycap.
    @objc private func gestureTapped(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, editingIndex < workingProfiles.count else { return }
        captureFields()   // fold the tap field's current text into the working copy first
        let tap = workingProfiles[editingIndex].bindings[name] ?? ""
        let hold = workingProfiles[editingIndex].hold[name] ?? ""
        let dbl = workingProfiles[editingIndex].double[name] ?? ""

        let alert = NSAlert()
        alert.messageText = "Secondary actions — \(name)"
        alert.informativeText = "Tap runs on a quick press. Hold runs on a long press; Double runs on a quick "
            + "double-tap. Leave Hold and Double blank to keep this key tap-only (no added latency)."

        let w: CGFloat = 380
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 96))
        func makeField(y: CGFloat, title: String, value: String) -> NSTextField {
            let lbl = NSTextField(labelWithString: title)
            lbl.frame = NSRect(x: 0, y: y, width: 60, height: 20)
            lbl.alignment = .right
            container.addSubview(lbl)
            let f = NSTextField(frame: NSRect(x: 68, y: y - 2, width: w - 68, height: 24))
            f.stringValue = value
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.placeholderString = "(none)"
            container.addSubview(f)
            return f
        }
        let tapField = makeField(y: 68, title: "Tap:", value: tap)
        let holdField = makeField(y: 36, title: "Hold:", value: hold)
        let dblField = makeField(y: 4, title: "Double:", value: dbl)
        tapField.placeholderString = "(disabled)"
        alert.accessoryView = container
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = holdField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let t = tapField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = holdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = dblField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        workingProfiles[editingIndex].bindings[name] = t
        workingProfiles[editingIndex].hold[name] = h.isEmpty ? nil : h
        workingProfiles[editingIndex].double[name] = d.isEmpty ? nil : d
        fields[name]?.stringValue = t
        deviceView.updateBinding(name, t)
        updateGestureIndicator(name)
        savedLabel.stringValue = "\(name): secondary actions updated — Save to apply"
    }

    /// Mark a key's ⋯ button when it has hold/double actions (H / D / HD), so they're
    /// visible without opening the sheet.
    private func updateGestureIndicator(_ name: String) {
        guard let b = gestureButtons[name], editingIndex < workingProfiles.count else { return }
        let h = !(workingProfiles[editingIndex].hold[name] ?? "").isEmpty
        let d = !(workingProfiles[editingIndex].double[name] ?? "").isEmpty
        if h || d {
            b.title = (h ? "H" : "") + (d ? "D" : "")
            b.toolTip = "Has secondary actions — click to edit"
        } else {
            b.title = "⋯"
            b.toolTip = "Add a hold (long-press) or double-tap action for this key"
        }
    }

    private func updateGestureIndicators() { for name in gestureButtons.keys { updateGestureIndicator(name) } }

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
        deviceView.select(name)
        guard let field = fields[name] else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
        field.scrollToVisible(field.bounds)
    }

    // MARK: - Live edit → device map

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let name = field.identifier?.rawValue else { return }
        deviceView.updateBinding(name, field.stringValue.trimmingCharacters(in: .whitespaces))
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
        captureFields()
        // Global options are set before the profile write so everything persists in one go.
        mapping.knobSpinRepeat = (spinCheckbox.state == .on)
        mapping.knobMaxRepeat = maxRepeatStepper.integerValue
        mapping.holdMs = holdStepper.integerValue
        mapping.doubleTapMs = doubleStepper.integerValue
        mapping.replaceAllProfiles(workingProfiles.map {
            Mapping.ProfileBindings(name: $0.name, tap: $0.bindings, hold: $0.hold, double: $0.double)
        })
        onProfilesChanged?()
        flashSaved()
    }

    @objc private func resetTapped() {
        let defaults = Mapping.defaultsDict()
        for (name, field) in fields { field.stringValue = defaults[name] ?? "" }
        syncDevice()
        let who = workingProfiles.isEmpty ? "default" : workingProfiles[editingIndex].name
        savedLabel.stringValue = "Defaults loaded for \(who) — press Save to apply"
    }

    // MARK: - Profile switching

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < workingProfiles.count, idx != editingIndex else { return }
        captureFields()
        editingIndex = idx
        populateFields()
        removeButton.isEnabled = (workingProfiles[editingIndex].name != "default")
        updateProfileHint()
    }

    @objc private func addProfileTapped() {
        let alert = NSAlert()
        alert.messageText = "Add a profile"
        alert.informativeText = "Creates a named profile, seeded as a copy of your default bindings — "
            + "change only what should differ. Cycle to it with the knob press; the active profile "
            + "shows by the menu-bar icon."
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.placeholderString = "Profile name (e.g. cTrader)"
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { savedLabel.stringValue = "Enter a profile name"; return }

        captureFields()
        if let existing = workingProfiles.firstIndex(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) {
            editingIndex = existing
            rebuildProfilePopup(); populateFields(); updateProfileHint()
            savedLabel.stringValue = "Already have a profile named “\(workingProfiles[existing].name)” — selected it"
            return
        }
        let name = uniqueName(raw)
        let def = workingProfiles.first(where: { $0.name == "default" })
        workingProfiles.append(EditProfile(name: name, bindings: def?.bindings ?? Mapping.defaultsDict(),
                                           hold: def?.hold ?? [:], double: def?.double ?? [:]))
        editingIndex = workingProfiles.count - 1
        rebuildProfilePopup(); populateFields(); updateProfileHint()
        savedLabel.stringValue = "Added \(name) — edit and Save to apply"
    }

    @objc private func removeProfileTapped() {
        guard editingIndex < workingProfiles.count,
              workingProfiles[editingIndex].name != "default" else { return }
        let removed = workingProfiles.remove(at: editingIndex)
        editingIndex = 0
        rebuildProfilePopup(); populateFields(); updateProfileHint()
        savedLabel.stringValue = "Removed \(removed.name) — Save to apply"
    }

    // MARK: - Export / import

    @objc private func exportSelected(_ sender: NSPopUpButton) {
        captureFields()
        switch sender.indexOfSelectedItem {
        case 1: exportProfile(all: false)
        case 2: exportProfile(all: true)
        default: break
        }
    }

    private func exportProfile(all: Bool) {
        guard let window, editingIndex < workingProfiles.count else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = all
            ? "kd100-mapping.json"
            : "\(workingProfiles[editingIndex].name).kd100profile.json"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let data: Data = all
                ? ProfileIO.encodeAll(self.workingProfiles.map { ($0.name, $0.bindings, $0.hold, $0.double) })
                : ProfileIO.encodeProfile(name: self.workingProfiles[self.editingIndex].name,
                                          bindings: self.workingProfiles[self.editingIndex].bindings,
                                          hold: self.workingProfiles[self.editingIndex].hold,
                                          double: self.workingProfiles[self.editingIndex].double)
            do {
                try data.write(to: url)
                self.savedLabel.stringValue = "Exported \(url.lastPathComponent)"
            } catch {
                self.savedLabel.stringValue = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    @objc private func importTapped() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let incoming = ProfileIO.decode(data), !incoming.isEmpty else {
                self.savedLabel.stringValue = "Import failed — not a kd100 profile file"
                return
            }
            self.captureFields()
            var added = 0, updated = 0
            for prof in incoming {
                if let i = self.workingProfiles.firstIndex(where: { $0.name.caseInsensitiveCompare(prof.name) == .orderedSame }) {
                    if prof.name == "default" {
                        for (k, v) in prof.bindings { self.workingProfiles[i].bindings[k] = v }   // merge into default
                        for (k, v) in prof.hold { self.workingProfiles[i].hold[k] = v }
                        for (k, v) in prof.double { self.workingProfiles[i].double[k] = v }
                    } else {
                        self.workingProfiles[i].bindings = prof.bindings                            // replace same-named
                        self.workingProfiles[i].hold = prof.hold
                        self.workingProfiles[i].double = prof.double
                    }
                    updated += 1
                } else {
                    self.workingProfiles.append(EditProfile(name: self.uniqueName(prof.name),
                                                            bindings: prof.bindings, hold: prof.hold, double: prof.double))
                    added += 1
                }
            }
            self.editingIndex = min(self.editingIndex, self.workingProfiles.count - 1)
            self.rebuildProfilePopup(); self.populateFields(); self.updateProfileHint()
            self.savedLabel.stringValue = "Imported: \(added) added, \(updated) updated — Save to apply"
        }
    }

    /// A profile name unique within the current working set (and never "default").
    private func uniqueName(_ base: String) -> String {
        var stem = base.isEmpty ? "Profile" : base
        if stem == "default" { stem = "Default App" }
        let existing = Set(workingProfiles.map { $0.name })
        if !existing.contains(stem) { return stem }
        var n = 2
        while existing.contains("\(stem) (\(n))") { n += 1 }
        return "\(stem) (\(n))"
    }

    // MARK: - Working-model <-> fields

    /// Read the current field values into the profile being edited.
    private func captureFields() {
        guard editingIndex < workingProfiles.count else { return }
        var b: [String: String] = [:]
        for (name, field) in fields {
            b[name] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        workingProfiles[editingIndex].bindings = b
    }

    /// Fill the fields from the profile being edited, then sync the device map and the
    /// per-key gesture indicators.
    private func populateFields() {
        let b = (editingIndex < workingProfiles.count) ? workingProfiles[editingIndex].bindings : [:]
        for (name, field) in fields { field.stringValue = b[name] ?? "" }
        syncDevice()
        updateGestureIndicators()
    }

    /// Point the device map at the on-screen field values for the active profile, marking
    /// keys that carry a hold/double action in this profile.
    private func syncDevice() {
        guard deviceView != nil else { return }
        var b: [String: String] = [:]
        for (name, field) in fields { b[name] = field.stringValue.trimmingCharacters(in: .whitespaces) }
        let name = (editingIndex < workingProfiles.count) ? workingProfiles[editingIndex].name : "default"
        var sec: Set<String> = []
        if editingIndex < workingProfiles.count {
            let p = workingProfiles[editingIndex]
            for k in Mapping.order where !(p.hold[k] ?? "").isEmpty || !(p.double[k] ?? "").isEmpty { sec.insert(k) }
        }
        deviceView.update(profile: name, tint: Theme.tint(for: name), bindings: b, secondary: sec)
    }

    private func rebuildProfilePopup() {
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: workingProfiles.map { $0.name })
        if editingIndex < workingProfiles.count { profilePopup.selectItem(at: editingIndex) }
        removeButton.isEnabled = (editingIndex < workingProfiles.count
                                  && workingProfiles[editingIndex].name != "default")
    }

    private func updateProfileHint() {
        guard editingIndex < workingProfiles.count else { profileHint.stringValue = ""; return }
        let p = workingProfiles[editingIndex]
        if p.name == "default" {
            profileHint.stringValue = "Default profile. Press the knob to cycle to the next profile (shown by the menu-bar icon)."
        } else {
            profileHint.stringValue = "Profile \"\(p.name)\". Cycle to it with the knob press. "
                + "Blank a key to disable it here; the knob press itself is reserved for switching."
        }
    }

    // MARK: - Load

    private func reload() {
        workingProfiles = mapping.profileNames().map { name in
            let kb = mapping.keyBindings(forProfile: name)
            return EditProfile(name: name, bindings: kb.tap, hold: kb.hold, double: kb.double)
        }
        if workingProfiles.isEmpty {
            workingProfiles = [EditProfile(name: "default", bindings: Mapping.defaultsDict())]
        }
        if editingIndex >= workingProfiles.count { editingIndex = 0 }
        rebuildProfilePopup()
        populateFields()
        updateProfileHint()
        syncKnobOptions()
        syncGestureOptions()
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
