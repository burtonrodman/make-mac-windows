import ApplicationServices
import Cocoa

/// Snaps the frontmost window maximized/minimized, and cycles it through the
/// configured snap zones (see `SnapZones`) — mirroring Windows' Win+Arrow
/// snap shortcuts, triggered here by Option+Arrow (see
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
    enum CycleDirection {
        case next, previous
    }

    /// Steps the frontmost window forward/backward through every configured
    /// snap zone on every monitor (`SnapZones.allZonesOrdered()`), wrapping
    /// around at either end — mirroring Windows' Win+Left/Right, generalized
    /// from a fixed left/right half to however many zones each monitor is
    /// configured with (1-3; see `SnapZones`/`SettingsWindowController`).
    ///
    /// If the window isn't currently sitting in any configured zone, the
    /// press snaps it into whichever zone on its *current* screen is
    /// spatially closest to where it already is, regardless of direction —
    /// there's no "current" zone yet to step forward/backward from. Only
    /// once the window is inside a recognized zone does `direction` take
    /// over, stepping to the next/previous zone in the global order
    /// (including across monitors).
    static func cycleZone(_ direction: CycleDirection) {
        guard let (window, screen) = focusedWindowAndScreen() else { return }
        let zones = SnapZones.allZonesOrdered()
        guard !zones.isEmpty, let frame = currentCocoaFrame(of: window) else { return }

        if let currentIndex = zones.firstIndex(where: { rectsApproximatelyEqual($0.frame, frame) }) {
            let nextIndex = direction == .next
                ? (currentIndex + 1) % zones.count
                : (currentIndex - 1 + zones.count) % zones.count
            setFrame(zones[nextIndex].frame, on: window)
            return
        }

        let zonesOnCurrentScreen = SnapZones.displayID(of: screen).map { displayID in
            zones.filter { $0.displayID == displayID }
        } ?? []
        guard let closest = closestZone(to: frame, among: zonesOnCurrentScreen.isEmpty ? zones : zonesOnCurrentScreen) else {
            return
        }
        setFrame(closest.frame, on: window)
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

    // MARK: - Snap zone cycling helpers

    /// The window's current frame, converted into the same Cocoa
    /// bottom-left-origin space `SnapZones.Zone.frame` is expressed in.
    private static func currentCocoaFrame(of window: AXUIElement) -> CGRect? {
        guard let axFrame = currentFrame(of: window), let primaryHeight = primaryScreen?.frame.height else {
            return nil
        }
        return cocoaFrame(fromAX: axFrame, primaryHeight: primaryHeight)
    }

    /// Within a few points in every dimension — some apps round or add a
    /// hairline offset when asked to resize, so an exact match would be too
    /// brittle.
    private static func rectsApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        let dx = abs(lhs.origin.x - rhs.origin.x)
        let dy = abs(lhs.origin.y - rhs.origin.y)
        let dw = abs(lhs.width - rhs.width)
        let dh = abs(lhs.height - rhs.height)
        return dx < tolerance && dy < tolerance && dw < tolerance && dh < tolerance
    }

    /// The zone whose center is nearest the window's current center — used
    /// when the window isn't already sitting in a recognized zone, so the
    /// first Start+Left/Right press snaps it somewhere spatially sensible
    /// instead of always jumping to a screen edge (see `cycleZone`).
    private static func closestZone(to frame: CGRect, among zones: [SnapZones.Zone]) -> SnapZones.Zone? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return zones.min {
            distanceSquared(center, zoneCenter($0)) < distanceSquared(center, zoneCenter($1))
        }
    }

    private static func zoneCenter(_ zone: SnapZones.Zone) -> CGPoint {
        CGPoint(x: zone.frame.midX, y: zone.frame.midY)
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
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

    /// Same conversion as `axOrigin(forCocoaRect:primaryHeight:)`, applied
    /// the other direction (its formula is self-inverse): an AX frame's
    /// top-left origin becomes a Cocoa frame's bottom-left origin once the
    /// height is folded in.
    private static func cocoaFrame(fromAX axFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: axFrame.origin.x,
            y: primaryHeight - axFrame.origin.y - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )
    }
}
