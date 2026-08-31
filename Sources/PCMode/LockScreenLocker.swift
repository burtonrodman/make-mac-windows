import Carbon.HIToolbox
import Cocoa

/// Locks the screen by simulating macOS's default Lock Screen shortcut,
/// Control+Command+Q — there's no public API to lock the screen directly.
/// If the user has changed Lock Screen's shortcut in System Settings >
/// Keyboard > Keyboard Shortcuts > Lock Screen, this won't do anything; the
/// same known limitation as `SpotlightOpener`.
enum LockScreenLocker {
    static func lock() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false)
        else {
            return
        }

        keyDown.flags = [.maskControl, .maskCommand]
        keyUp.flags = [.maskControl, .maskCommand]

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
