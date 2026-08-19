import Cocoa

/// A single on-screen window, independent of which app owns it. This is the
/// unit PCMode's switcher cycles over, instead of macOS's default per-app
/// grouping (Cmd+Tab).
struct WindowInfo {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect

    /// Falls back to the owning app's name when the window has no title
    /// (common for single-window utility apps).
    var displayName: String {
        title.isEmpty ? ownerName : title
    }

    var icon: NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
    }

    /// A live-at-this-moment snapshot of the window's on-screen contents, for
    /// the switcher's preview cards. `nil` without Screen Recording
    /// permission (see `AppDelegate.requestScreenRecordingPermissionIfNeeded`)
    /// or if the window has since closed — callers should fall back to
    /// showing just the app icon in that case.
    var previewImage: NSImage? {
        // `windowID == 0` marks a windowless-app entry (see
        // `WindowLister.listWindows`) — there's no real window to grab a
        // thumbnail of, so skip straight to the app-icon fallback.
        guard windowID != 0, let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ), cgImage.width > 0, cgImage.height > 0 else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }
}

enum WindowLister {
    /// Bundle IDs of apps known to keep permanent, invisible "overlay"
    /// windows around — one full-monitor-sized window per connected display,
    /// used for the app's own OSD/hotkey handling rather than anything a
    /// user would switch to. They're opaque, ordinary-layer, and bigger than
    /// the tiny-helper-window cutoff below, so nothing else about them looks
    /// unusual — see `listWindows` for the title-based check that actually
    /// tells them apart from a real window.
    ///
    /// - `Qisda.DDPM`: Dell/BenQ's Display & Peripheral Manager, confirmed via
    ///   `defaults read .../DDPM.app/Contents/Info.plist CFBundleIdentifier`.
    ///   Shows up as two untitled, full-screen, on-screen windows (one per
    ///   monitor) at all times.
    private static let phantomOverlayBundleIDs: Set<String> = ["Qisda.DDPM"]

    /// Lists normal, on-screen windows across all apps, ordered front-to-back
    /// (as returned by the window server). That ordering doubles as a decent
    /// most-recently-used approximation, since activating a window brings it
    /// to the front.
    ///
    /// Known v1 limitation: minimized windows are excluded (CGWindowList only
    /// reports on-screen windows). Windows' Alt-Tab includes minimized
    /// windows too — that's a natural follow-up, not blocking v1.
    static func listWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: AnyObject]]
        else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        let windows = rawList.compactMap { entry -> WindowInfo? in
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                pid_t(ownerPID) != ownPID,
                let windowNumber = entry[kCGWindowNumber as String] as? Int,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else {
                return nil
            }

            // Skip fully transparent windows (offscreen buffers, some
            // overlay/decoration windows report layer 0 but alpha 0).
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                return nil
            }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Filter out menu-extras / tooltips / tiny helper windows that
            // technically sit at layer 0 but aren't "windows" a user would
            // want to switch to.
            guard bounds.width > 60, bounds.height > 40 else { return nil }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""

            // See `phantomOverlayBundleIDs` — scoped to *untitled* windows
            // from those specific apps so a real, user-facing window (which
            // always carries a title) still shows up if one's ever open.
            if title.isEmpty, let bundleID = NSRunningApplication(processIdentifier: pid_t(ownerPID))?.bundleIdentifier,
                Self.phantomOverlayBundleIDs.contains(bundleID) {
                return nil
            }

            return WindowInfo(
                windowID: CGWindowID(windowNumber),
                pid: pid_t(ownerPID),
                ownerName: ownerName,
                title: title,
                bounds: bounds
            )
        }

        // Running, Dock-visible apps that own none of the on-screen windows
        // above (no window open at all, or everything minimized/off-screen)
        // still get an entry — icon only, `windowID: 0` so `previewImage`
        // skips straight to that fallback — so the switcher can bring them
        // forward instead of silently omitting them.
        let pidsWithWindows = Set(windows.map(\.pid))
        let windowlessApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && app.processIdentifier != ownPID
                    && !pidsWithWindows.contains(app.processIdentifier)
            }
            .map { app in
                WindowInfo(
                    windowID: 0,
                    pid: app.processIdentifier,
                    ownerName: app.localizedName ?? "",
                    title: "",
                    bounds: .zero
                )
            }

        return windows + windowlessApps
    }
}
