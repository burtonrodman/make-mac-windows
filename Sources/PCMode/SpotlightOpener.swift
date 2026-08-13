import Carbon.HIToolbox
import Cocoa

/// Opens Spotlight by simulating its default keyboard shortcut, Cmd+Space —
/// there's no public API to invoke Spotlight directly. If the user has
/// changed Spotlight's shortcut in System Settings > Keyboard > Keyboard
/// Shortcuts > Spotlight, this won't do anything; a known v1 limitation.
enum SpotlightOpener {
    static func open() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Space), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Space), keyDown: false)
        else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
