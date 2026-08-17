import Cocoa
import UniformTypeIdentifiers

/// PCMode's Settings window, one tab per concern: which physical modifier
/// key does what (see `ModifierKeys.swift`); the "Excluded Apps" list for
/// the Control+A/C/S/V remap feature — which apps are exempted from having
/// their literal Control+A/C/S/V remapped to Command+A/C/S/V (see
/// `HotkeyEventTap` and `Preferences.ctrlCVDenylistBundleIDs`), with terminal
/// emulators and remote-desktop/VM consoles seeded in by default since they
/// need the literal keystroke (SIGINT, XOFF, raw paste-through, etc.) rather
/// than Mac-style select-all/copy/save/paste; the "Per-App Mappings" table
/// (see `PerAppKeyRemap.swift`) — add/edit/remove app-specific shortcut
/// rewrites like Chrome's Ctrl+H → Cmd+Y, each opened in
/// `PerAppMappingEditorSheet`; and "Snap Zones" — the Option+Arrow
/// snap/cycle shortcut's on/off switch alongside its per-monitor zone editor
/// (1-3 draggable left-to-right zones per screen), previously its own
/// separate window.
///
/// A plain programmatic `NSWindow` (no nib/storyboard), matching the rest of
/// PCMode's UI (`SwitcherPanel`). Kept alive as a singleton so the window
/// isn't torn down and rebuilt every time it's opened from the menu.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private static let padding: CGFloat = 20
    private static let snapStripHeight: CGFloat = 70

    private let tableView = NSTableView()
    private var bundleIDs: [String] = []
    private var modifierPopups: [ModifierSlot: NSPopUpButton] = [:]

    private let mappingsTableView = NSTableView()
    private var perAppKeyRemaps: [PerAppKeyRemap] = []
    private let perAppEnabledCheckbox = NSButton(
        checkboxWithTitle: "Enable per-app key mappings", target: nil, action: nil
    )
    /// Kept alive while its sheet is up — `NSWindow.windowController` is a
    /// weak reference, so nothing else holds this once `presentMappingEditor`
    /// returns.
    private var mappingEditorSheet: PerAppMappingEditorSheet?

    private let snapShortcutsCheckbox = NSButton(
        checkboxWithTitle: "Option + Arrow Snaps/Cycles Windows", target: nil, action: nil
    )
    /// Holds one row per connected monitor (see `rebuildSnapZoneRows`) —
    /// rebuilt every time the window is shown, since monitors can be
    /// connected/disconnected while it's closed and there's no notification
    /// wired up to catch that.
    private let snapZonesStack = NSStackView()
    private var snapStripViews: [CGDirectDisplayID: SnapZoneStripView] = [:]
    private var snapCountPopups: [CGDirectDisplayID: NSPopUpButton] = [:]

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PCMode Settings"
        window.center()
        // Accessory apps (no dock icon) have no other window to fall back
        // to when this one closes, so keep it around rather than dealloc'd
        // on close — cheap to keep alive, and avoids rebuilding the tables
        // and their data source wiring from scratch every time.
        window.isReleasedWhenClosed = false

        self.init(window: window)
        buildUI()
    }

    /// Brings the window to the front, refreshing every tab's contents from
    /// `Preferences` first in case they were edited elsewhere (e.g. a future
    /// second settings surface, or manual `defaults write`).
    func show() {
        bundleIDs = Preferences.shared.ctrlCVDenylistBundleIDs.sorted()
        tableView.reloadData()
        for (slot, popup) in modifierPopups {
            selectRole(Preferences.shared.role(for: slot), in: popup, for: slot)
        }
        perAppKeyRemaps = Preferences.shared.perAppKeyRemaps
        mappingsTableView.reloadData()
        perAppEnabledCheckbox.state = Preferences.shared.perAppKeyRemapEnabled ? .on : .off
        snapShortcutsCheckbox.state = Preferences.shared.snapShortcutsEnabled ? .on : .off
        rebuildSnapZoneRows()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab(title: "Modifier Keys", content: buildModifierKeysSection()))
        tabView.addTabViewItem(makeTab(title: "Excluded Apps", content: buildExcludedAppsSection()))
        tabView.addTabViewItem(makeTab(title: "Per-App Mappings", content: buildPerAppMappingsSection()))
        tabView.addTabViewItem(makeTab(title: "Snap Zones", content: buildSnapSection()))

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    /// Wraps one section's bare content stack in its own padded tab item —
    /// the only place that knows about tab padding, so `buildXSection`
    /// methods stay focused on their own content.
    private func makeTab(title: String, content: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title

        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -Self.padding),
        ])
        item.view = container
        return item
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
                "— tap-for-Spotlight, the window switcher, window snap, Control+A/C/S/V, and " +
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
        let heading = NSTextField(labelWithString: "Apps Excluded from Control+A/C/S/V Remap")
        heading.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "PCMode remaps Control+A/C/S/V to Command+A/C/S/V everywhere except " +
                "the apps below — typically terminals and remote-desktop/VM consoles, " +
                "where the literal keystroke needs to reach the app (e.g. Control+C as " +
                "an interrupt signal, or Control+S as an XOFF that freezes output).")
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

    /// "App / From / To" table of `PerAppKeyRemap`s, plus an on/off checkbox
    /// for the feature as a whole and Add/Edit/Remove/Reset buttons that
    /// open `PerAppMappingEditorSheet` or mutate `perAppKeyRemaps` directly.
    private func buildPerAppMappingsSection() -> NSView {
        let heading = NSTextField(labelWithString: "Per-App Key Mappings")
        heading.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "Windows-style shortcuts specific apps kept instead of adopting the " +
                "native Mac equivalent — e.g. Chrome's Ctrl+H for History, rewritten " +
                "here to Chrome's own Cmd+Y. Each modifier in the app's shortcut can " +
                "require a specific physical key (Left/Right) or either one.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

        perAppEnabledCheckbox.target = self
        perAppEnabledCheckbox.action = #selector(perAppEnabledToggled)

        for (identifier, title, width) in [("app", "App", CGFloat(150)), ("from", "From", 110), ("to", "To", 110)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            mappingsTableView.addTableColumn(column)
        }
        mappingsTableView.usesAlternatingRowBackgroundColors = true
        mappingsTableView.dataSource = self
        mappingsTableView.delegate = self
        mappingsTableView.doubleAction = #selector(editSelectedMapping)
        mappingsTableView.target = self

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = mappingsTableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 160).isActive = true

        let addButton = NSButton(title: "Add Mapping…", target: self, action: #selector(addMapping))
        let editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedMapping))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelectedMapping))
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetMappingsToDefaults))
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [addButton, editButton, removeButton, spacer, resetButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, explanation, perAppEnabledCheckbox, scrollView, buttonRow])
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

    @objc private func perAppEnabledToggled() {
        Preferences.shared.perAppKeyRemapEnabled = perAppEnabledCheckbox.state == .on
    }

    @objc private func addMapping() {
        presentMappingEditor(editing: nil, atIndex: nil)
    }

    @objc private func editSelectedMapping() {
        let index = mappingsTableView.selectedRow
        guard perAppKeyRemaps.indices.contains(index) else { return }
        presentMappingEditor(editing: perAppKeyRemaps[index], atIndex: index)
    }

    @objc private func removeSelectedMapping() {
        let indices = mappingsTableView.selectedRowIndexes
        guard !indices.isEmpty else { return }
        for index in indices.sorted(by: >) {
            perAppKeyRemaps.remove(at: index)
        }
        Preferences.shared.perAppKeyRemaps = perAppKeyRemaps
        mappingsTableView.reloadData()
    }

    @objc private func resetMappingsToDefaults() {
        perAppKeyRemaps = PerAppKeyRemaps.defaultProfile
        Preferences.shared.perAppKeyRemaps = perAppKeyRemaps
        mappingsTableView.reloadData()
    }

    /// Presents `PerAppMappingEditorSheet` to add a new mapping (`index ==
    /// nil`) or edit the one at `index`. Keeps `mappingEditorSheet` alive
    /// for the duration — see that property's doc for why that's needed.
    private func presentMappingEditor(editing existing: PerAppKeyRemap?, atIndex index: Int?) {
        guard let window else { return }
        // Held in a local `let` (and then `mappingEditorSheet`) from the
        // start — `NSWindow.windowController` is weak, so fetching the
        // controller back out via `sheetWindow.windowController` after the
        // fact would already be `nil` by then.
        let sheet = PerAppMappingEditorSheet(editing: existing)
        guard let sheetWindow = sheet.window else { return }

        sheet.onSave = { [weak self] remap in
            guard let self else { return }
            if let index, self.perAppKeyRemaps.indices.contains(index) {
                self.perAppKeyRemaps[index] = remap
            } else {
                self.perAppKeyRemaps.append(remap)
            }
            Preferences.shared.perAppKeyRemaps = self.perAppKeyRemaps
            self.mappingsTableView.reloadData()
        }
        mappingEditorSheet = sheet
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.mappingEditorSheet = nil
        }
    }

    /// The on/off switch for Option+Arrow snap/cycle, plus one row per
    /// connected monitor (label + 1-3 zone-count popup + a draggable
    /// `SnapZoneStripView`) — previously split between a menu checkbox and
    /// a separate "Snap Zones…" window, now combined here. What
    /// `WindowSnapper.cycleZone` reads back via `Preferences.snapZoneSplits`/
    /// `SnapZones` when Option+Left/Right steps the frontmost window
    /// through every zone on every monitor.
    private func buildSnapSection() -> NSView {
        let heading = NSTextField(labelWithString: "Snap Zones")
        heading.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "Each monitor is divided into 1-3 left-to-right zones. Start+Left/Right steps " +
                "the focused window through every zone on every monitor, in order — drag a " +
                "divider below to adjust the split.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

        snapShortcutsCheckbox.target = self
        snapShortcutsCheckbox.action = #selector(snapShortcutsToggled)

        snapZonesStack.orientation = .vertical
        snapZonesStack.alignment = .leading
        snapZonesStack.spacing = 16
        snapZonesStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, explanation, snapShortcutsCheckbox, snapZonesStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            snapZonesStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    @objc private func snapShortcutsToggled() {
        Preferences.shared.snapShortcutsEnabled = snapShortcutsCheckbox.state == .on
    }

    /// Rebuilds the monitor rows from the *current* screen arrangement —
    /// called every time the window is shown, since monitors can be
    /// connected/disconnected between opens with no notification wired up
    /// to catch that while the window is closed.
    private func rebuildSnapZoneRows() {
        snapZonesStack.arrangedSubviews.forEach {
            snapZonesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        snapStripViews = [:]
        snapCountPopups = [:]

        for screen in NSScreen.screens.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let displayID = SnapZones.displayID(of: screen) else { continue }
            snapZonesStack.addArrangedSubview(buildSnapRow(for: screen, displayID: displayID))
        }
    }

    private func buildSnapRow(for screen: NSScreen, displayID: CGDirectDisplayID) -> NSView {
        let size = screen.frame.size
        let label = NSTextField(labelWithString:
            "\(screen.localizedName) — \(Int(size.width))×\(Int(size.height))")
        label.font = .systemFont(ofSize: 12, weight: .medium)

        let splits = Preferences.shared.snapZoneSplits(forDisplayID: displayID)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for count in 1 ... SnapZones.maxZonesPerMonitor {
            popup.addItem(withTitle: "\(count) zone\(count == 1 ? "" : "s")")
        }
        popup.selectItem(at: (splits.count + 1) - 1)
        popup.target = self
        popup.action = #selector(snapZoneCountChanged(_:))
        popup.tag = Int(displayID)
        snapCountPopups[displayID] = popup

        let headerRow = NSStackView(views: [label, popup])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8

        let strip = SnapZoneStripView(displayID: displayID, screenSize: screen.visibleFrame.size, splits: splits)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onSplitsCommitted = { [weak self] newSplits in
            self?.commitSnapSplits(newSplits, forDisplayID: displayID)
        }
        snapStripViews[displayID] = strip

        let row = NSStackView(views: [headerRow, strip])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: row.widthAnchor),
            strip.widthAnchor.constraint(equalTo: row.widthAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.snapStripHeight),
        ])
        return row
    }

    @objc private func snapZoneCountChanged(_ sender: NSPopUpButton) {
        let displayID = CGDirectDisplayID(sender.tag)
        let count = sender.indexOfSelectedItem + 1
        let splits = SnapZones.evenSplits(forZoneCount: count)
        commitSnapSplits(splits, forDisplayID: displayID)
        snapStripViews[displayID]?.setSplits(splits)
    }

    private func commitSnapSplits(_ splits: [CGFloat], forDisplayID displayID: CGDirectDisplayID) {
        Preferences.shared.setSnapZoneSplits(splits, forDisplayID: displayID)
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === mappingsTableView ? perAppKeyRemaps.count : bundleIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === mappingsTableView {
            return mappingCell(for: tableColumn, row: row)
        }

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

    private func mappingCell(for column: NSTableColumn?, row: Int) -> NSView? {
        guard perAppKeyRemaps.indices.contains(row) else { return nil }
        let remap = perAppKeyRemaps[row]

        let text: String
        switch column?.identifier.rawValue {
        case "app": text = displayName(forBundleID: remap.bundleID)
        case "from": text = remap.fromDescription
        case "to": text = remap.toDescription
        default: text = ""
        }

        let identifier = NSUserInterfaceItemIdentifier("mappingCell")
        let cell = mappingsTableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = text
        cell.isEditable = false
        cell.isBordered = false
        cell.drawsBackground = false
        return cell
    }

    /// The app's own display name (e.g. "Google Chrome") when it's
    /// installed and findable, falling back to the raw bundle ID — using
    /// `NSWorkspace` rather than `NSRunningApplication` so it resolves
    /// whether or not the app happens to be running right now.
    private func displayName(forBundleID bundleID: String) -> String {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let info = Bundle(url: url)?.infoDictionary
        else {
            return bundleID
        }
        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
    }
}

/// A single monitor's zone editor: draws its 1-3 configured zones side by
/// side, each labeled with its real pixel size, and lets the user drag the
/// divider(s) between them to adjust the split, live (with a left/right
/// resize cursor over each divider). Purely a view over
/// `Preferences.snapZoneSplits` for one display — `SettingsWindowController`
/// owns the zone-count control and writes a fresh even split into this view
/// whenever the count changes.
private final class SnapZoneStripView: NSView {
    /// How close (in points) a mouseDown has to land to a divider's current
    /// position to start dragging it, rather than being ignored.
    private static let handleHitSlop: CGFloat = 10
    /// Smallest a zone is allowed to shrink to, as a fraction of the strip's
    /// full width — keeps a dragged divider from collapsing a neighboring
    /// zone to nothing (or crossing past the next divider).
    private static let minZoneFraction: CGFloat = 0.08

    private static let zoneColors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange]

    let displayID: CGDirectDisplayID
    /// The real display's zone-bearing size (its `visibleFrame`, in points —
    /// the same space `SnapZones.zones(for:)` slices up), used only to
    /// compute the pixel-size label drawn on each zone; unrelated to this
    /// view's own on-screen size.
    private let screenSize: CGSize
    /// Current split fractions (0-1, strictly increasing), live during a
    /// drag. Committed to `Preferences` only on mouseUp — see `mouseUp`.
    private(set) var splits: [CGFloat]
    /// Called with the final splits once a drag ends.
    var onSplitsCommitted: ((_ splits: [CGFloat]) -> Void)?

    private var draggingDividerIndex: Int?

    init(displayID: CGDirectDisplayID, screenSize: CGSize, splits: [CGFloat]) {
        self.displayID = displayID
        self.screenSize = screenSize
        self.splits = splits
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the splits wholesale (e.g. after the zone-count popup
    /// changes) and redraws — bypasses the drag-commit path since this isn't
    /// a user drag.
    func setSplits(_ newSplits: [CGFloat]) {
        splits = newSplits
        draggingDividerIndex = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let sizeLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]

        let bounds01 = [0.0] + splits.map(Double.init) + [1.0]
        for index in 0 ..< bounds01.count - 1 {
            let startFraction = bounds01[index]
            let endFraction = bounds01[index + 1]
            let x0 = bounds.width * CGFloat(startFraction)
            let x1 = bounds.width * CGFloat(endFraction)
            let zoneRect = NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).insetBy(dx: 3, dy: 3)
            let path = NSBezierPath(roundedRect: zoneRect, xRadius: 6, yRadius: 6)
            let color = Self.zoneColors[index % Self.zoneColors.count]
            color.withAlphaComponent(0.25).setFill()
            path.fill()
            color.setStroke()
            path.stroke()

            // The zone's real pixel footprint — i.e. what the window will
            // actually measure once snapped into it (see
            // `SnapZones.zones(for:)`, which slices this same `screenSize`).
            let pixelWidth = Int((CGFloat(endFraction - startFraction) * screenSize.width).rounded())
            let pixelHeight = Int(screenSize.height.rounded())
            let label = "\(pixelWidth) × \(pixelHeight)"
            let labelSize = label.size(withAttributes: sizeLabelAttributes)
            let labelOrigin = NSPoint(x: zoneRect.midX - labelSize.width / 2, y: zoneRect.midY - labelSize.height / 2)
            label.draw(at: labelOrigin, withAttributes: sizeLabelAttributes)
        }

        NSColor.separatorColor.setFill()
        for split in splits {
            let x = bounds.width * split
            NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8).fill()
        }
    }

    /// Shows a left/right resize cursor over each divider's hit area — the
    /// same tolerance `mouseDown` uses to decide whether a click starts a
    /// drag — so it's clear before the user even clicks that the divider is
    /// draggable. AppKit calls this automatically on hover/frame changes;
    /// `setSplits`/`mouseDragged` additionally invalidate it explicitly
    /// since divider positions can move without either of those.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard bounds.width > 0 else { return }
        for split in splits {
            let x = bounds.width * split
            let rect = NSRect(
                x: x - Self.handleHitSlop, y: 0, width: Self.handleHitSlop * 2, height: bounds.height
            )
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        let fraction = convert(event.locationInWindow, from: nil).x / bounds.width
        let hitSlopFraction = Self.handleHitSlop / bounds.width

        guard
            let nearest = splits.indices.min(by: { abs(splits[$0] - fraction) < abs(splits[$1] - fraction) }),
            abs(splits[nearest] - fraction) <= hitSlopFraction
        else {
            return
        }
        draggingDividerIndex = nearest
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = draggingDividerIndex, bounds.width > 0 else { return }
        NSCursor.resizeLeftRight.set()

        let lowerNeighbor = index == 0 ? 0 : splits[index - 1]
        let upperNeighbor = index == splits.count - 1 ? 1 : splits[index + 1]
        let lowerBound = lowerNeighbor + Self.minZoneFraction
        let upperBound = upperNeighbor - Self.minZoneFraction

        let fraction = convert(event.locationInWindow, from: nil).x / bounds.width
        splits[index] = min(max(fraction, lowerBound), upperBound)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard draggingDividerIndex != nil else { return }
        draggingDividerIndex = nil
        onSplitsCommitted?(splits)
    }
}
