import ApplicationServices
import Cocoa

/// Makes clicking an inactive window both activate it *and* deliver the
/// click — mirroring Windows, where the two always happen together. On
/// macOS, clicking a background window does activate it, but whether the
/// click itself reaches the view underneath is entirely up to that app
/// (`NSView.acceptsFirstMouse(with:)`, default `false`): most non-Apple apps
/// swallow the first click as activation-only, so a second click is needed
/// to actually press the button/link/whatever was clicked. There's no public
/// API for "activate this window and also deliver the click that caused it"
/// — and no way to change another process's `acceptsFirstMouse` from outside
/// — so instead, `HotkeyEventTap` hands every `leftMouseDown`/`leftMouseUp`
/// to this class first:
///
/// 1. On `leftMouseDown`, hit-test which window the click actually lands on
///    (see `targetNeedingActivation`). If it's already the frontmost app's
///    focused window, do nothing — the click proceeds completely normally.
/// 2. Otherwise, swallow the real `leftMouseDown`, raise/focus that specific
///    window via `WindowActivator`, and poll until that app is frontmost (or
///    give up after `maxWait`).
/// 3. Replay a synthetic `leftMouseDown` at the same point once ready. Since
///    the target is now frontmost, the app receives this as an ordinary
///    first click — including any subsequent real `mouseDragged`/
///    `leftMouseUp` events (e.g. dragging that inactive window by its title
///    bar), which are left alone and flow through untouched from here on.
/// 4. The one wrinkle: if the real `leftMouseUp` arrives before step 3 has
///    happened yet (a fast click/tap), there's no live mouse-down for it to
///    complete — so it's swallowed too, and the replay in step 3 sends a
///    synthetic `leftMouseUp` right after the synthetic down to close out
///    the gesture itself.
///
/// This is inherently a hack, so it's opt-in — see
/// `Preferences.clickThroughActivationEnabled`.
final class ClickThroughActivator {
    static let shared = ClickThroughActivator()

    /// How often to check whether the target app has become frontmost yet.
    private static let pollInterval: TimeInterval = 0.01
    /// Long enough for a same-Space activation (near-instant) and most
    /// cross-Space ones (the Space-switch animation); a click still waiting
    /// past this replays anyway rather than getting silently eaten.
    private static let maxWait: TimeInterval = 0.6

    private enum State {
        case idle
        /// A real `leftMouseDown` was swallowed and activation is pending.
        /// `upAlreadyHappened` is set if the matching real `leftMouseUp` has
        /// already arrived (and was swallowed) while still waiting.
        case pendingActivation(pid: pid_t, point: CGPoint, flags: CGEventFlags, clickState: Int64, upAlreadyHappened: Bool)
        /// The synthetic `leftMouseDown` has been sent; the next real
        /// `leftMouseUp` is the genuine tail of this gesture and should pass
        /// through untouched.
        case replayed
    }

    private var state: State = .idle

    private init() {}

    /// Called from `HotkeyEventTap` on every `leftMouseDown`, before any
    /// other handling. Returns `true` if the event was swallowed (an
    /// activate-then-replay is now pending) — the caller should return `nil`
    /// from the tap callback in that case.
    func handleMouseDown(event: CGEvent) -> Bool {
        guard Preferences.shared.clickThroughActivationEnabled else { return false }
        // Not idle means either a gesture is already in flight, or this
        // mouseDown *is* our own synthetic replay looping back through the
        // tap — either way, don't re-trigger.
        guard case .idle = state else { return false }
        guard let target = targetNeedingActivation(at: event.location) else { return false }

        state = .pendingActivation(
            pid: target.pid, point: event.location, flags: event.flags,
            clickState: event.getIntegerValueField(.mouseEventClickState), upAlreadyHappened: false
        )
        WindowActivator.activate(target.window)
        waitForActivationThenReplay(waited: 0)
        return true
    }

    /// Called from `HotkeyEventTap` on every `leftMouseUp`. Returns `true` if
    /// it should be swallowed — i.e. it's the premature tail of a click whose
    /// `leftMouseDown` was just eaten by `handleMouseDown` above, before the
    /// replay had a chance to happen.
    func handleMouseUp() -> Bool {
        switch state {
        case .idle:
            return false
        case .pendingActivation(let pid, let point, let flags, let clickState, _):
            state = .pendingActivation(
                pid: pid, point: point, flags: flags, clickState: clickState, upAlreadyHappened: true
            )
            return true
        case .replayed:
            state = .idle
            return false
        }
    }

    // MARK: - Hit testing

    private struct ActivationTarget {
        let pid: pid_t
        let window: WindowInfo
    }

    /// Finds the topmost real window under `point` and reports it back only
    /// if clicking it needs PCMode's help — i.e. its owning app isn't
    /// already frontmost, or (a multi-window app) it isn't that app's
    /// currently-focused window. `point` is in the same top-left-origin,
    /// Y-down "global display" space `CGWindowListCopyWindowInfo` reports
    /// bounds in, which is also what `CGEvent.location` uses.
    private func targetNeedingActivation(at point: CGPoint) -> ActivationTarget? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return nil
        }

        // Front-to-back order — whatever's truly topmost at the point is
        // what the click actually lands on.
        guard
            let hit = rawList.first(where: { entry in
                Self.bounds(from: entry)?.contains(point) ?? false
            })
        else {
            return nil
        }
        // Only an ordinary (layer 0) window is a background *app* window we
        // can usefully activate. If the topmost thing here is anything else
        // — an open menu (pulldown/popup), the menu bar itself, a status-item
        // popover, the Dock — that's what will actually receive the click,
        // so leave it alone rather than skipping past it to a window
        // further back (which would swallow the real click and misdirect
        // activation to that background window instead).
        guard
            let layer = hit[kCGWindowLayer as String] as? Int, layer == 0,
            let ownerPID = hit[kCGWindowOwnerPID as String] as? Int,
            pid_t(ownerPID) != ownPID,
            let windowNumber = hit[kCGWindowNumber as String] as? Int
        else {
            return nil
        }

        let pid = pid_t(ownerPID)
        let windowID = CGWindowID(windowNumber)
        guard !isAlreadyFocused(windowID: windowID, ofPID: pid) else { return nil }

        let window = WindowInfo(
            windowID: windowID,
            pid: pid,
            ownerName: hit[kCGWindowOwnerName as String] as? String ?? "",
            title: hit[kCGWindowName as String] as? String ?? "",
            bounds: Self.bounds(from: hit) ?? .zero
        )
        return ActivationTarget(pid: pid, window: window)
    }

    private static func bounds(from entry: [String: AnyObject]) -> CGRect? {
        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(
            x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
        )
    }

    /// True when `windowID` is already `pid`'s focused window *and* `pid` is
    /// already the frontmost app — the one case where the click needs no
    /// help from PCMode at all.
    private func isAlreadyFocused(windowID: CGWindowID, ofPID pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }

        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &windowRef
            ) == .success,
            windowRef != nil
        else {
            // No AX-reported focused window (or AX unavailable for this
            // app) — "app is already frontmost" is good enough on its own.
            return true
        }
        let axWindow = windowRef as! AXUIElement

        var focusedID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &focusedID) == .success else { return true }
        return focusedID == windowID
    }

    // MARK: - Replay

    private func waitForActivationThenReplay(waited: TimeInterval) {
        guard case .pendingActivation(let pid, let point, let flags, let clickState, let upAlreadyHappened) = state
        else {
            return
        }

        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard isFrontmost || waited >= Self.maxWait else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
                self?.waitForActivationThenReplay(waited: waited + Self.pollInterval)
            }
            return
        }

        post(.leftMouseDown, at: point, flags: flags, clickState: clickState)
        if upAlreadyHappened {
            post(.leftMouseUp, at: point, flags: flags, clickState: clickState)
            state = .idle
        } else {
            state = .replayed
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags, clickState: Int64) {
        guard let synthetic = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
        ) else {
            return
        }
        synthetic.flags = flags
        synthetic.setIntegerValueField(.mouseEventClickState, value: clickState)
        synthetic.post(tap: .cghidEventTap)
    }
}
