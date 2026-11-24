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
///
/// Every public way to make another app frontmost —
/// `NSRunningApplication.activate`, setting `kAXFrontmostAttribute` — brings
/// *all* of that app's windows forward, interleaving nothing. Windows only
/// raises the one window you picked. When
/// `Preferences.activateSingleWindowEnabled` is on (the default), PCMode
/// instead uses `SingleWindowFocuser` (private SkyLight calls) to make just
/// the target window key and frontmost, falling back to the public
/// all-windows path if those calls are unavailable or fail.
enum WindowActivator {
    static func activate(_ window: WindowInfo) {
        // `pid == 0` marks a recently-used-but-now-quit app (see
        // `WindowInfo.bundleIdentifier`/`WindowLister.recentlyQuitApps`) —
        // there's no running process to activate a window within, so launch
        // it fresh instead.
        guard window.pid != 0 else {
            launch(bundleIdentifier: window.bundleIdentifier)
            return
        }

        let appElement = AXUIElementCreateApplication(window.pid)
        let axWindow = findAXWindow(id: window.windowID, in: appElement)
        let runningApp = NSRunningApplication(processIdentifier: window.pid)

        // Unhiding a hidden (Cmd+H) app inherently brings back all of its
        // windows, so there's nothing to gain from the single-window path
        // there — use the public one.
        let canFocusSingleWindow = Preferences.shared.activateSingleWindowEnabled
            && runningApp?.isHidden != true

        if let axWindow {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        if canFocusSingleWindow, SingleWindowFocuser.focus(pid: window.pid, windowID: window.windowID) {
            // SkyLight made the app frontmost with only this window ordered
            // forward; AXRaise settles its order among the app's own windows
            // (and is a no-op if AX can't see the window, e.g. some Java apps).
            if let axWindow {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
            return
        }

        // Public fallback: brings the whole app (all its windows) forward...
        runningApp?.activate(options: [.activateIgnoringOtherApps])

        // ...then raises the specific window within it.
        guard let axWindow else { return }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func findAXWindow(id windowID: CGWindowID, in appElement: AXUIElement) -> AXUIElement? {
        var axWindowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &axWindowsRef
        )
        guard err == .success, let axWindows = axWindowsRef as? [AXUIElement] else {
            return nil
        }
        return axWindows.first { axWindow in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(axWindow, &wid) == .success && wid == windowID
        }
    }

    private static func launch(bundleIdentifier: String?) {
        guard
            let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Makes one specific window of another app key and frontmost *without*
/// bringing the rest of that app's windows forward — the same technique
/// AltTab and similar window switchers use. It relies on private SkyLight
/// (WindowServer client) functions, so every symbol is looked up at runtime
/// with `dlsym`: if a future macOS removes or renames one, `focus` returns
/// `false` and `WindowActivator` falls back to the public all-windows path
/// rather than crashing.
private enum SingleWindowFocuser {
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus
    private typealias SetFrontProcessWithOptionsFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    private typealias PostEventRecordToFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError

    /// `kCPSUserGenerated`: treat the activation as user-initiated and order
    /// forward only the given window rather than every window of the app.
    private static let userGeneratedMode: UInt32 = 0x200

    private struct Functions {
        let getProcessForPID: GetProcessForPIDFn
        let setFrontProcessWithOptions: SetFrontProcessWithOptionsFn
        let postEventRecordTo: PostEventRecordToFn
    }

    private static let functions: Functions? = {
        guard
            let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let appServices = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY
            ),
            let getPSN = dlsym(appServices, "GetProcessForPID"),
            let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
            let postEvent = dlsym(skyLight, "SLPSPostEventRecordTo")
        else {
            NSLog("PCMode: SkyLight single-window activation unavailable; falling back to app activation")
            return nil
        }
        return Functions(
            getProcessForPID: unsafeBitCast(getPSN, to: GetProcessForPIDFn.self),
            setFrontProcessWithOptions: unsafeBitCast(setFront, to: SetFrontProcessWithOptionsFn.self),
            postEventRecordTo: unsafeBitCast(postEvent, to: PostEventRecordToFn.self)
        )
    }()

    /// Returns `true` if the window was made frontmost via SkyLight.
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let functions, windowID != 0 else { return false }

        var psn = ProcessSerialNumber()
        guard functions.getProcessForPID(pid, &psn) == noErr else { return false }
        guard functions.setFrontProcessWithOptions(&psn, windowID, userGeneratedMode) == .success else {
            return false
        }
        makeKeyWindow(psn: &psn, windowID: windowID, post: functions.postEventRecordTo)
        return true
    }

    /// Posts the synthetic WindowServer event records that tell the app the
    /// given window is now its key window — the step `_SLPSSetFrontProcess…`
    /// alone doesn't do (without it, the app is frontmost but keystrokes may
    /// still go to whichever of its windows was key before). The 0xF8-byte
    /// record layout is the reverse-engineered one used by AltTab, yabai and
    /// Hammerspoon.
    private static func makeKeyWindow(
        psn: inout ProcessSerialNumber, windowID: CGWindowID, post: PostEventRecordToFn
    ) {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { widBytes in
            for (offset, byte) in widBytes.enumerated() { bytes[0x3C + offset] = byte }
        }
        for offset in 0x20..<0x30 { bytes[offset] = 0xFF }

        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
    }
}
