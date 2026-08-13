import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissionIfNeeded()
        requestScreenRecordingPermissionIfNeeded()
        statusItemController.setup()
        HotkeyEventTap.shared.onOptionTap = {
            SpotlightOpener.open()
        }
        HotkeyEventTap.shared.onCommandTap = {
            SpotlightOpener.open()
        }
        SwitcherController.shared.start()
        startPermissionPollingIfNeeded()
    }

    /// Triggers the system Accessibility-permission prompt on first launch
    /// (adds PCMode to System Settings > Privacy & Security > Accessibility,
    /// unchecked, if it isn't already present). The window-switching feature
    /// needs this to (a) install a global event tap for the trigger+Tab
    /// hotkey and (b) raise/focus windows belonging to other apps.
    private func requestAccessibilityPermissionIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        NSLog("[PCMode] Accessibility trusted at launch: \(trusted)")
    }

    /// Since macOS 10.15, `CGWindowListCopyWindowInfo`'s window-title field
    /// comes back empty for every window not owned by the calling process
    /// unless it also holds Screen Recording permission — Accessibility
    /// alone isn't enough. Without it, PCMode's switcher can only fall back
    /// to showing the owning app's name instead of the real window title.
    private func requestScreenRecordingPermissionIfNeeded() {
        let trusted = CGPreflightScreenCaptureAccess()
        NSLog("[PCMode] Screen Recording trusted at launch: \(trusted)")
        if !trusted {
            // Triggers the system prompt / adds PCMode (unchecked) to
            // System Settings > Privacy & Security > Screen Recording.
            CGRequestScreenCaptureAccess()
        }
    }

    /// If Accessibility wasn't granted yet at launch, keep checking in the
    /// background and re-install the event tap the moment it is — so
    /// granting the permission takes effect immediately, with no need to
    /// quit and relaunch PCMode.
    private func startPermissionPollingIfNeeded() {
        guard !HotkeyEventTap.shared.isInstalled else { return }

        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            HotkeyEventTap.shared.start()
            if HotkeyEventTap.shared.isInstalled {
                timer.invalidate()
                self?.permissionPollTimer = nil
            }
        }
    }
}
