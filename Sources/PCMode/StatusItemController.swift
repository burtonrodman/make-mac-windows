import Cocoa

/// The menu-bar icon that will grow into the control center for every
/// PCMode module (keyboard, mouse, window management). For now it offers
/// the switcher's trigger, the tap-to-open-Spotlight toggles, the
/// Option+Arrow window-snapping toggle, and Quit.
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let triggerOffItem = NSMenuItem()
    private let triggerOptionItem = NSMenuItem()
    private let triggerCommandItem = NSMenuItem()
    private let optionSpotlightToggleItem = NSMenuItem()
    private let commandSpotlightToggleItem = NSMenuItem()
    private let snapShortcutsToggleItem = NSMenuItem()

    func setup() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.stack",
                accessibilityDescription: "PCMode"
            )
        }

        let menu = NSMenu()

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

        snapShortcutsToggleItem.title = "Option + Arrow Snaps Windows"
        snapShortcutsToggleItem.action = #selector(toggleSnapShortcuts)
        snapShortcutsToggleItem.target = self
        menu.addItem(snapShortcutsToggleItem)

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

    private func updateCheckmarks() {
        let current = Preferences.shared.switcherTrigger
        triggerOffItem.state = current == .off ? .on : .off
        triggerOptionItem.state = current == .option ? .on : .off
        triggerCommandItem.state = current == .command ? .on : .off

        optionSpotlightToggleItem.state = Preferences.shared.optionTapOpensSpotlight ? .on : .off
        commandSpotlightToggleItem.state = Preferences.shared.commandTapOpensSpotlight ? .on : .off
        snapShortcutsToggleItem.state = Preferences.shared.snapShortcutsEnabled ? .on : .off
    }
}
