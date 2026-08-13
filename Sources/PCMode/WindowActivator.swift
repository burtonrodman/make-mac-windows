import ApplicationServices
import Cocoa

// `_AXUIElementGetWindow` is a private-but-widely-relied-upon function
// exported by HIServices/ApplicationServices. It's the standard technique
// (used by many macOS window-management utilities) for mapping an
// AXUIElement window back to the CGWindowID that CGWindowListCopyWindowInfo
// gives us, since there's no public API for that lookup. It's undocumented,
// not GPL/copied code — just a known symbol we declare ourselves.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindow: inout CGWindowID) -> AXError

/// Raises and focuses a specific window (not just its owning app), using the
/// Accessibility API. This is what lets PCMode's switcher pick a single
/// window out of an app that has several, which Cmd+Tab can't do.
enum WindowActivator {
    static func activate(_ window: WindowInfo) {
        let appElement = AXUIElementCreateApplication(window.pid)

        // Bring the app itself frontmost first...
        NSRunningApplication(processIdentifier: window.pid)?
            .activate(options: [.activateIgnoringOtherApps])

        // ...then find and raise the specific window within it.
        var axWindowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &axWindowsRef
        )
        guard err == .success, let axWindows = axWindowsRef as? [AXUIElement] else {
            return
        }

        for axWindow in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &wid) == .success, wid == window.windowID else {
                continue
            }

            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            break
        }
    }
}
