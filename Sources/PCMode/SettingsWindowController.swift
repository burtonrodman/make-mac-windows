import Cocoa
import UniformTypeIdentifiers

/// PCMode's Settings window: which physical modifier key does what (see
/// `ModifierKeys.swift`), and the "Manage Excluded Apps" list for the
/// Control+C/V remap feature — shows and edits which apps are exempted from
/// having their literal Control+C/V remapped to Command+C/V (see
/// `HotkeyEventTap` and `Preferences.ctrlCVDenylistBundleIDs`). Terminal
/// emulators and remote-desktop/VM consoles are seeded in by default, since
/// they need the literal keystroke (SIGINT, raw paste-through, etc.) rather
/// than Mac-style copy/paste.
///
/// A plain programmatic `NSWindow` (no nib/storyboard), matching the rest of
/// PCMode's UI (`SwitcherPanel`). Kept alive as a singleton so the window
/// isn't torn down and rebuilt every time it's opened from the menu.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private static let padding: CGFloat = 20

    private let tableView = NSTableView()
    private var bundleIDs: [String] = []
    private var modifierPopups: [ModifierSlot: NSPopUpButton] = [:]

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PCMode Settings"
        window.center()
        // Accessory apps (no dock icon) have no other window to fall back
        // to when this one closes, so keep it around rather than dealloc'd
        // on close — cheap to keep alive, and avoids rebuilding the table
        // and its data source wiring from scratch every time.
        window.isReleasedWhenClosed = false

        self.init(window: window)
        buildUI()
    }

    /// Brings the window to the front, refreshing its contents from
    /// `Preferences` first in case they were edited elsewhere (e.g. a future
    /// second settings surface, or manual `defaults write`).
    func show() {
        bundleIDs = Preferences.shared.ctrlCVDenylistBundleIDs.sorted()
        tableView.reloadData()
        for (slot, popup) in modifierPopups {
            selectRole(Preferences.shared.role(for: slot), in: popup, for: slot)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let modifierSection = buildModifierKeysSection()
        let divider = NSBox()
        divider.boxType = .separator
        let excludedAppsSection = buildExcludedAppsSection()

        let stack = NSStackView(views: [modifierSection, divider, excludedAppsSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        // The padding lives on these outer constraints, pinning the stack
        // itself inset from contentView's edges, rather than on
        // `stack.edgeInsets` — edgeInsets only pads arranged subviews away
        // from the stack's own frame, and the width==stack.widthAnchor
        // constraints below would cancel that padding right back out by
        // forcing every child to span the stack's full (uninset) width.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.padding),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.padding),
            modifierSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            excludedAppsSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// One popup per physical modifier key (see `ModifierSlot`), in Mac
    /// keyboard order left to right, letting each be reassigned among the
    /// roles it makes sense for (`ModifierSlot.allowedRoles`). This is what
    /// lets e.g. Right Option default to Control instead of joining Left
    /// Option in the Start-key bundle — see `ModifierKeys.swift` for why.
    private func buildModifierKeysSection() -> NSView {
        let heading = NSTextField(labelWithString: "Modifier Keys")
        heading.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "What each physical modifier key does for the shortcuts PCMode handles below " +
                "— tap-for-Spotlight, the window switcher, window snap, Control+C/V, and " +
                "Home/End navigation. This never changes what a key sends to other apps; " +
                "it only changes which key(s) PCMode itself reacts to.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

        var rows: [NSView] = [heading, explanation]
        for slot in ModifierSlot.allCases {
            rows.append(buildModifierRow(for: slot))
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows where row !== heading && row !== explanation {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func buildModifierRow(for slot: ModifierSlot) -> NSView {
        let label = NSTextField(labelWithString: slot.displayName)
        label.font = .systemFont(ofSize: 12)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for role in slot.allowedRoles {
            popup.addItem(withTitle: role.displayName)
        }
        popup.target = self
        popup.action = #selector(modifierRoleChanged(_:))
        modifierPopups[slot] = popup
        selectRole(Preferences.shared.role(for: slot), in: popup, for: slot)

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // Tag the row's only popup with the slot's index so the action
        // handler can look the slot back up without a second dictionary
        // keyed by NSPopUpButton identity.
        popup.tag = ModifierSlot.allCases.firstIndex(of: slot) ?? 0
        return row
    }

    private func selectRole(_ role: ModifierRole, in popup: NSPopUpButton, for slot: ModifierSlot) {
        if let index = slot.allowedRoles.firstIndex(of: role) {
            popup.selectItem(at: index)
        }
    }

    @objc private func modifierRoleChanged(_ sender: NSPopUpButton) {
        let slot = ModifierSlot.allCases[sender.tag]
        let role = slot.allowedRoles[sender.indexOfSelectedItem]
        Preferences.shared.setRole(role, for: slot)
    }

    private func buildExcludedAppsSection() -> NSView {
        let heading = NSTextField(labelWithString: "Apps Excluded from Control+C/V Remap")
        heading.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "PCMode remaps Control+C and Control+V to Command+C/V everywhere except " +
                "the apps below — typically terminals and remote-desktop/VM consoles, " +
                "where the literal keystroke needs to reach the app (e.g. Control+C as " +
                "an interrupt signal).")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        column.title = "Bundle Identifier"
        column.width = 380
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(addApp))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [addButton, removeButton, spacer, resetButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, explanation, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    @objc private func addApp() {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addBundleIDs(from: panel.urls)
        }
    }

    /// Silently skips any picked app with no bundle identifier — vanishingly
    /// rare for anything in `/Applications`, but `Bundle(url:)` is failable
    /// and there's no sane fallback identifier to add instead.
    private func addBundleIDs(from urls: [URL]) {
        var updated = Set(bundleIDs)
        for url in urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                updated.insert(bundleID)
            }
        }
        bundleIDs = updated.sorted()
        Preferences.shared.ctrlCVDenylistBundleIDs = bundleIDs
        tableView.reloadData()
    }

    @objc private func removeSelected() {
        let indices = tableView.selectedRowIndexes
        guard !indices.isEmpty else { return }
        // Descending order so earlier removals don't shift the indices of
        // ones still to come.
        for index in indices.sorted(by: >) {
            bundleIDs.remove(at: index)
        }
        Preferences.shared.ctrlCVDenylistBundleIDs = bundleIDs
        tableView.reloadData()
    }

    @objc private func resetDefaults() {
        bundleIDs = Preferences.defaultCtrlCVDenylist.sorted()
        Preferences.shared.ctrlCVDenylistBundleIDs = bundleIDs
        tableView.reloadData()
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        bundleIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("bundleIDCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = bundleIDs[row]
        cell.isEditable = false
        cell.isBordered = false
        cell.drawsBackground = false
        return cell
    }
}
