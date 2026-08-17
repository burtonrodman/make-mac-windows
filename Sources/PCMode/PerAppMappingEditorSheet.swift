import Cocoa

/// One row in the mapping editor's modifier grid: a checkbox for whether
/// this modifier participates in the chord, and — only on the "from" side,
/// where physical side matters (see `ModifierSide`) — a Left/Right/Either
/// popup enabled only while the checkbox is checked. The "to" side skips
/// the popup entirely: the synthesized keystroke has no physical side to
/// fake (see `PerAppKeyRemap.toModifiers`).
private final class ModifierRow: NSObject {
    let base: ModifierRequirement.Base
    let view: NSView
    private let checkbox: NSButton
    private let sidePopup: NSPopUpButton?

    init(base: ModifierRequirement.Base, includeSide: Bool) {
        self.base = base
        checkbox = NSButton(checkboxWithTitle: base.displayName, target: nil, action: nil)
        checkbox.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        if includeSide {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for side in ModifierSide.allCases {
                popup.addItem(withTitle: side.displayName)
            }
            popup.selectItem(withTitle: ModifierSide.both.displayName)
            sidePopup = popup
        } else {
            sidePopup = nil
        }

        let row = NSStackView(views: sidePopup == nil ? [checkbox] : [checkbox, sidePopup!])
        row.orientation = .horizontal
        row.spacing = 8
        view = row

        super.init()

        checkbox.target = self
        checkbox.action = #selector(checkboxToggled)
        updateEnabled()
    }

    @objc private func checkboxToggled() {
        updateEnabled()
    }

    private func updateEnabled() {
        sidePopup?.isEnabled = checkbox.state == .on
    }

    /// The requirement this row currently represents, or `nil` while its
    /// checkbox is off. Only meaningful on the "from" side.
    var requirement: ModifierRequirement? {
        guard checkbox.state == .on else { return nil }
        let side = sidePopup.map { ModifierSide.allCases[$0.indexOfSelectedItem] } ?? .both
        return ModifierRequirement(base: base, side: side)
    }

    /// Whether this modifier participates at all — used on the "to" side,
    /// which has no side to include in a `ModifierRequirement`.
    var isChecked: Bool { checkbox.state == .on }

    func configure(checked: Bool, side: ModifierSide = .both) {
        checkbox.state = checked ? .on : .off
        if let sidePopup, let index = ModifierSide.allCases.firstIndex(of: side) {
            sidePopup.selectItem(at: index)
        }
        updateEnabled()
    }
}

/// Add/edit sheet for a single `PerAppKeyRemap`, presented by
/// `SettingsWindowController`. A plain programmatic `NSWindow` (no nib),
/// matching the rest of PCMode's UI.
final class PerAppMappingEditorSheet: NSWindowController {
    /// Called with the finished mapping once "Save" is clicked; never called
    /// if the sheet is cancelled.
    var onSave: ((PerAppKeyRemap) -> Void)?

    private let bundleIDField = NSTextField(string: "")
    private let fromKeyRecorder = KeyRecorderField()
    private let toKeyRecorder = KeyRecorderField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var fromRows: [ModifierRow] = []
    private var toRows: [ModifierRow] = []

    convenience init(editing existing: PerAppKeyRemap?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil ? "Add Mapping" : "Edit Mapping"
        self.init(window: window)
        buildUI()
        if let existing {
            configure(with: existing)
        }
        updateSaveEnabled()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        fromKeyRecorder.onCapture = { [weak self] _ in self?.updateSaveEnabled() }
        toKeyRecorder.onCapture = { [weak self] _ in self?.updateSaveEnabled() }

        let appRow = buildAppRow()
        let (fromSection, fRows) = buildChordSection(
            heading: "From — this app's current shortcut",
            recorder: fromKeyRecorder,
            includeSide: true
        )
        fromRows = fRows
        let (toSection, tRows) = buildChordSection(
            heading: "To — Mac shortcut to send instead",
            recorder: toKeyRecorder,
            includeSide: false
        )
        toRows = tRows

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [appRow, fromSection, toSection, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            appRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fromSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func buildAppRow() -> NSView {
        let label = NSTextField(labelWithString: "App:")
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        bundleIDField.placeholderString = "com.example.App"
        bundleIDField.translatesAutoresizingMaskIntoConstraints = false
        bundleIDField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        bundleIDField.delegate = self

        let chooseButton = NSButton(title: "Choose App…", target: self, action: #selector(chooseApp))

        let row = NSStackView(views: [label, bundleIDField, chooseButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func buildChordSection(
        heading: String, recorder: KeyRecorderField, includeSide: Bool
    ) -> (NSView, [ModifierRow]) {
        let headingLabel = NSTextField(labelWithString: heading)
        headingLabel.font = .boldSystemFont(ofSize: 12)

        let keyLabel = NSTextField(labelWithString: "Key:")
        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let keyRow = NSStackView(views: [keyLabel, recorder])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8

        let rows = ModifierRequirement.Base.allCases.map { ModifierRow(base: $0, includeSide: includeSide) }
        let modifiersLabel = NSTextField(labelWithString: "Modifiers:")
        modifiersLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let rowsStack = NSStackView(views: rows.map(\.view))
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4

        let modifiersRow = NSStackView(views: [modifiersLabel, rowsStack])
        modifiersRow.orientation = .horizontal
        modifiersRow.alignment = .top
        modifiersRow.spacing = 8

        let section = NSStackView(views: [headingLabel, keyRow, modifiersRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return (section, rows)
    }

    private func configure(with remap: PerAppKeyRemap) {
        bundleIDField.stringValue = remap.bundleID
        fromKeyRecorder.keyCode = remap.fromKeyCode
        toKeyRecorder.keyCode = remap.toKeyCode
        for row in fromRows {
            if let requirement = remap.fromModifiers.first(where: { $0.base == row.base }) {
                row.configure(checked: true, side: requirement.side)
            } else {
                row.configure(checked: false)
            }
        }
        for row in toRows {
            row.configure(checked: remap.toModifiers.contains(row.base))
        }
    }

    private func updateSaveEnabled() {
        let hasBundleID = !bundleIDField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        saveButton.isEnabled = hasBundleID && fromKeyRecorder.keyCode != nil && toKeyRecorder.keyCode != nil
    }

    @objc private func chooseApp() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard
                response == .OK,
                let url = panel.urls.first,
                let bundleID = Bundle(url: url)?.bundleIdentifier
            else {
                return
            }
            self?.bundleIDField.stringValue = bundleID
            self?.updateSaveEnabled()
        }
    }

    @objc private func save() {
        guard
            let fromKeyCode = fromKeyRecorder.keyCode,
            let toKeyCode = toKeyRecorder.keyCode,
            let window,
            let sheetParent = window.sheetParent
        else {
            return
        }

        let remap = PerAppKeyRemap(
            bundleID: bundleIDField.stringValue.trimmingCharacters(in: .whitespaces),
            fromKeyCode: fromKeyCode,
            fromModifiers: fromRows.compactMap(\.requirement),
            toKeyCode: toKeyCode,
            toModifiers: toRows.filter(\.isChecked).map(\.base)
        )
        onSave?(remap)
        sheetParent.endSheet(window)
    }

    @objc private func cancel() {
        guard let window, let sheetParent = window.sheetParent else { return }
        sheetParent.endSheet(window)
    }
}

extension PerAppMappingEditorSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateSaveEnabled()
    }
}
