import Cocoa

/// The menu-bar icon that will grow into the control center for every
/// PCMode module (keyboard, mouse, window management). For now it offers a
/// link to `SettingsWindowController` (per-physical-key modifier role
/// assignment, and the Control+A/C/S/V remap's per-app exclusions), the
/// switcher's trigger, the tap-to-open-Spotlight toggles, the Option+Arrow
/// window-snapping toggle, a link to `SnapZonesWindowController` (per-monitor
/// snap zone count/split), the Control+A/C/S/V remap toggle, the Home/End
/// line/document-navigation remap toggle, the Command+F4 close-window
/// toggle, and Quit.
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let triggerOffItem = NSMenuItem()
    private let triggerOptionItem = NSMenuItem()
    private let triggerCommandItem = NSMenuItem()
    private let optionSpotlightToggleItem = NSMenuItem()
    private let commandSpotlightToggleItem = NSMenuItem()
    private let snapShortcutsToggleItem = NSMenuItem()
    private let ctrlCVRemapToggleItem = NSMenuItem()
    private let homeEndRemapToggleItem = NSMenuItem()
    private let closeWindowToggleItem = NSMenuItem()

    func setup() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.stack",
                accessibilityDescription: "PCMode"
            )
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Modifier Keys & Settings…", action: #selector(showSettings), keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let triggerHeader = NSMenuItem(title: "Window Switcher", action: nil, keyEquivalent: "")
        triggerHeader.isEnabled = false
        menu.addItem(triggerHeader)

        triggerOffItem.title = SwitcherTrigger.off.displayName
        triggerOffItem.action = #selector(selectOffTrigger)
        triggerOffItem.target = self
        menu.addItem(triggerOffItem)

        triggerOptionItem.title = SwitcherTrigger.option.displayName
        triggerOptionItem.action = #selector(selectOptionTrigger)
        triggerOptionItem.target = self
        menu.addItem(triggerOptionItem)

        triggerCommandItem.title = SwitcherTrigger.command.displayName
        triggerCommandItem.action = #selector(selectCommandTrigger)
        triggerCommandItem.target = self
        menu.addItem(triggerCommandItem)

        menu.addItem(.separator())

        let spotlightHeader = NSMenuItem(title: "Windows-Key-Style Shortcut", action: nil, keyEquivalent: "")
        spotlightHeader.isEnabled = false
        menu.addItem(spotlightHeader)

        optionSpotlightToggleItem.title = "Tap Option to Open Spotlight"
        optionSpotlightToggleItem.action = #selector(toggleOptionTapSpotlight)
        optionSpotlightToggleItem.target = self
        menu.addItem(optionSpotlightToggleItem)

        commandSpotlightToggleItem.title = "Tap Command to Open Spotlight"
        commandSpotlightToggleItem.action = #selector(toggleCommandTapSpotlight)
        commandSpotlightToggleItem.target = self
        menu.addItem(commandSpotlightToggleItem)

        menu.addItem(.separator())

        let snapHeader = NSMenuItem(title: "Snap Windows", action: nil, keyEquivalent: "")
        snapHeader.isEnabled = false
        menu.addItem(snapHeader)

        snapShortcutsToggleItem.title = "Option + Arrow Snaps/Cycles Windows"
        snapShortcutsToggleItem.action = #selector(toggleSnapShortcuts)
        snapShortcutsToggleItem.target = self
        menu.addItem(snapShortcutsToggleItem)

        let snapZonesItem = NSMenuItem(
            title: "Snap Zones…", action: #selector(showSnapZones), keyEquivalent: ""
        )
        snapZonesItem.target = self
        menu.addItem(snapZonesItem)

        menu.addItem(.separator())

        let copyPasteHeader = NSMenuItem(title: "Select All / Copy / Save / Paste", action: nil, keyEquivalent: "")
        copyPasteHeader.isEnabled = false
        menu.addItem(copyPasteHeader)

        ctrlCVRemapToggleItem.title = "Control+A/C/S/V → Command+A/C/S/V"
        ctrlCVRemapToggleItem.action = #selector(toggleCtrlCVRemap)
        ctrlCVRemapToggleItem.target = self
        menu.addItem(ctrlCVRemapToggleItem)

        menu.addItem(.separator())

        let navigationHeader = NSMenuItem(title: "Line / Document Navigation", action: nil, keyEquivalent: "")
        navigationHeader.isEnabled = false
        menu.addItem(navigationHeader)

        homeEndRemapToggleItem.title = "Home/End → Line, Control+Home/End → Document"
        homeEndRemapToggleItem.action = #selector(toggleHomeEndRemap)
        homeEndRemapToggleItem.target = self
        menu.addItem(homeEndRemapToggleItem)

        menu.addItem(.separator())

        let closeWindowHeader = NSMenuItem(title: "Close Window", action: nil, keyEquivalent: "")
        closeWindowHeader.isEnabled = false
        menu.addItem(closeWindowHeader)

        closeWindowToggleItem.title = "Command + F4 Closes Focused Window"
        closeWindowToggleItem.action = #selector(toggleCloseWindowShortcut)
        closeWindowToggleItem.target = self
        menu.addItem(closeWindowToggleItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit PCMode",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
        updateCheckmarks()
    }

    @objc private func selectOffTrigger() {
        Preferences.shared.switcherTrigger = .off
        updateCheckmarks()
    }

    @objc private func selectOptionTrigger() {
        Preferences.shared.switcherTrigger = .option
        updateCheckmarks()
    }

    @objc private func selectCommandTrigger() {
        Preferences.shared.switcherTrigger = .command
        updateCheckmarks()
    }

    @objc private func toggleOptionTapSpotlight() {
        Preferences.shared.optionTapOpensSpotlight.toggle()
        updateCheckmarks()
    }

    @objc private func toggleCommandTapSpotlight() {
        Preferences.shared.commandTapOpensSpotlight.toggle()
        updateCheckmarks()
    }

    @objc private func toggleSnapShortcuts() {
        Preferences.shared.snapShortcutsEnabled.toggle()
        updateCheckmarks()
    }

    @objc private func toggleCtrlCVRemap() {
        Preferences.shared.ctrlCVRemapEnabled.toggle()
        updateCheckmarks()
    }

    @objc private func toggleHomeEndRemap() {
        Preferences.shared.homeEndRemapEnabled.toggle()
        updateCheckmarks()
    }

    @objc private func toggleCloseWindowShortcut() {
        Preferences.shared.closeWindowShortcutEnabled.toggle()
        updateCheckmarks()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func showSnapZones() {
        SnapZonesWindowController.shared.show()
    }

    private func updateCheckmarks() {
        let current = Preferences.shared.switcherTrigger
        triggerOffItem.state = current == .off ? .on : .off
        triggerOptionItem.state = current == .option ? .on : .off
        triggerCommandItem.state = current == .command ? .on : .off

        optionSpotlightToggleItem.state = Preferences.shared.optionTapOpensSpotlight ? .on : .off
        commandSpotlightToggleItem.state = Preferences.shared.commandTapOpensSpotlight ? .on : .off
        snapShortcutsToggleItem.state = Preferences.shared.snapShortcutsEnabled ? .on : .off
        ctrlCVRemapToggleItem.state = Preferences.shared.ctrlCVRemapEnabled ? .on : .off
        homeEndRemapToggleItem.state = Preferences.shared.homeEndRemapEnabled ? .on : .off
        closeWindowToggleItem.state = Preferences.shared.closeWindowShortcutEnabled ? .on : .off
    }
}
