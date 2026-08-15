import ApplicationServices
import Cocoa

/// Snaps the frontmost window left/right/maximized/minimized — mirroring
/// Windows' Win+Arrow snap shortcuts, triggered here by Option+Arrow (see
/// `HotkeyEventTap`/`AppDelegate`). Unlike `WindowActivator` (which raises a
/// specific *already-known* `WindowInfo`), this always acts on whatever
/// window is currently focused, since the trigger is a plain hotkey with no
/// window picker involved.
///
/// AXUIElement's position/size attributes live in the same top-left-origin,
/// Y-down "global display" coordinate space as `CGWindowListCopyWindowInfo`
/// bounds — not Cocoa's bottom-left-origin `NSScreen.frame`. Every
/// AX-facing rect here is converted through `cocoaRect`/`axOrigin` to avoid
/// windows landing on the wrong screen or upside-down on a multi-monitor
/// setup.
enum WindowSnapper {
    enum Edge {
        case left, right
    }

    static func snap(to edge: Edge) {
        guard let (window, screen) = focusedWindowAndScreen() else { return }
        var half = screen.visibleFrame
        half.size.width = half.width / 2
        if edge == .right {
            half.origin.x += half.width
        }
        setFrame(half, on: window)
    }

    static func maximize() {
        guard let (window, screen) = focusedWindowAndScreen() else { return }
        setFrame(screen.visibleFrame, on: window)
    }

    static func minimize() {
        guard let (window, _) = focusedWindowAndScreen() else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - Focused window lookup

    /// The primary display — the one whose frame has its origin at (0, 0)
    /// in Cocoa coordinates — is what every AX/Cocoa coordinate conversion
    /// here is anchored to.
    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    private static func focusedWindowAndScreen() -> (AXUIElement, NSScreen)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &windowRef
            ) == .success
        else {
            return nil
        }
        let window = windowRef as! AXUIElement

        let screen = screenContaining(window) ?? primaryScreen
        guard let screen else { return nil }
        return (window, screen)
    }

    private static func screenContaining(_ window: AXUIElement) -> NSScreen? {
        guard let axFrame = currentFrame(of: window), let primaryScreen else { return nil }
        let axCenter = CGPoint(x: axFrame.midX, y: axFrame.midY)
        let cocoaCenter = cocoaPoint(fromAX: axCenter, primaryHeight: primaryScreen.frame.height)
        return NSScreen.screens.first { $0.frame.contains(cocoaCenter) }
    }

    private static func currentFrame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func setFrame(_ cocoaFrame: CGRect, on window: AXUIElement) {
        guard let primaryHeight = primaryScreen?.frame.height else { return }

        var origin = axOrigin(forCocoaRect: cocoaFrame, primaryHeight: primaryHeight)
        var size = cocoaFrame.size

        guard
            let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return
        }

        // Set size before position: some apps clamp/re-center a window when
        // its size changes, which would otherwise clobber the position we
        // just set. Setting position again afterwards guards against that.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    // MARK: - Coordinate conversion (Cocoa bottom-left-origin <-> AX/CG top-left-origin)

    private static func cocoaPoint(fromAX axPoint: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: axPoint.x, y: primaryHeight - axPoint.y)
    }

    private static func axOrigin(forCocoaRect rect: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height)
    }
}
