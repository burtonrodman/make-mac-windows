import ApplicationServices
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
    /// (as returned by the window server), followed by any minimized windows
    /// (see `minimizedWindows` — CGWindowList itself never reports those).
    /// The on-screen ordering doubles as a decent most-recently-used
    /// approximation, since activating a window brings it to the front.
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

        let minimized = minimizedWindows(knownWindowIDs: Set(windows.map(\.windowID)), ownPID: ownPID)

        // Running, Dock-visible apps that own none of the windows above (no
        // window open at all, or every window hidden via Cmd+H rather than
        // minimized — minimized ones are now covered by `minimized`) still
        // get an entry — icon only, `windowID: 0` so `previewImage` skips
        // straight to that fallback — so the switcher can bring them forward
        // instead of silently omitting them.
        //
        // Apps from `phantomOverlayBundleIDs` are excluded here too, by
        // bundle ID rather than by pid-in-this-snapshot: their overlay
        // windows aren't always present in a given CGWindowList snapshot
        // (DDPM, for one, is frequently caught with zero on-screen windows
        // at all), so relying on this pass having actually seen and filtered
        // one isn't reliable. These apps have no real window to bring
        // forward and, being background utilities, activating them just
        // leaves an empty menu bar behind — so they shouldn't get a switcher
        // entry at all.
        //
        // Also excluded: any bundle ID that already owns a real window
        // above under a *different* pid. Some apps (VS Code chief among
        // them, via `--new-window`/`--extensionDevelopmentPath`) run as
        // multiple separate OS processes sharing one bundle ID; if one of
        // those processes' windows has since closed while the process
        // itself lingers, it would otherwise show up as a bare icon
        // duplicate of the app whose real window is already listed.
        let pidsWithWindows = Set(windows.map(\.pid) + minimized.map(\.pid))
        let bundleIDsWithWindows = Set(pidsWithWindows.compactMap { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        })
        let windowlessApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && app.processIdentifier != ownPID
                    && !pidsWithWindows.contains(app.processIdentifier)
                    && !(app.bundleIdentifier.map(Self.phantomOverlayBundleIDs.contains) ?? false)
                    && !(app.bundleIdentifier.map(bundleIDsWithWindows.contains) ?? false)
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

        return windows + minimized + windowlessApps
    }

    /// Minimized windows across all apps, found via the Accessibility API
    /// since `CGWindowListCopyWindowInfo` never reports them (even without
    /// `.optionOnScreenOnly` — a minimized window simply isn't in the window
    /// server's list at all). Mirrors how `WindowActivator` already looks
    /// windows up by `AXUIElement` to un-minimize and raise them.
    private static func minimizedWindows(knownWindowIDs: Set<CGWindowID>, ownPID: pid_t) -> [WindowInfo] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && app.processIdentifier != ownPID
                    && !(app.bundleIdentifier.map(Self.phantomOverlayBundleIDs.contains) ?? false)
            }
            .flatMap { app -> [WindowInfo] in
                let pid = app.processIdentifier
                var axWindowsRef: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(
                    AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &axWindowsRef
                )
                guard err == .success, let axWindows = axWindowsRef as? [AXUIElement] else {
                    return []
                }

                return axWindows.compactMap { axWindow -> WindowInfo? in
                    var minimizedRef: CFTypeRef?
                    guard
                        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                        (minimizedRef as? Bool) == true
                    else {
                        return nil
                    }

                    var windowID: CGWindowID = 0
                    guard _AXUIElementGetWindow(axWindow, &windowID) == .success,
                        !knownWindowIDs.contains(windowID)
                    else {
                        return nil
                    }

                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                    let title = titleRef as? String ?? ""

                    return WindowInfo(
                        windowID: windowID,
                        pid: pid,
                        ownerName: app.localizedName ?? "",
                        title: title,
                        bounds: .zero
                    )
                }
            }
    }
}
