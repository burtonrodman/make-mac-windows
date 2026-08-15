import ApplicationServices
import Cocoa

/// Closes the focused window — mirroring Windows' Alt+F4, triggered here by
/// Option+F4 (see `HotkeyEventTap`/`AppDelegate`). Like `WindowSnapper`, this
/// always acts on whatever window is currently focused, since the trigger is
/// a plain hotkey with no window picker involved.
///
/// This presses the window's AX close button rather than posting Cmd+W:
/// Cmd+W's actual binding varies by app (some tie it to "close tab" rather
/// than "close window", and it isn't guaranteed to be bound at all), while
/// the close button — when the window has one — is the exact same control a
/// user would click, so this always matches what clicking the red dot does.
enum WindowCloser {
    static func closeFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &windowRef
            ) == .success
        else {
            return
        }
        let window = windowRef as! AXUIElement

        var closeButtonRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                window, kAXCloseButtonAttribute as CFString, &closeButtonRef
            ) == .success
        else {
            return
        }
        let closeButton = closeButtonRef as! AXUIElement
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    }
}
