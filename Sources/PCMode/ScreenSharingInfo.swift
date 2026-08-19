import Cocoa
import Darwin
import SystemConfiguration

/// Whether this Mac is involved in a Screen Sharing session right now —
/// either as the client (running Screen Sharing.app to view another Mac) or
/// the host (someone else viewing/controlling this Mac over the network).
/// Used to label the window switcher (see `SwitcherPanel`) with *this* Mac's
/// own name whenever either is true, since it's otherwise easy to forget
/// which physical Mac you're actually typing into once a Screen Sharing
/// window is in the mix.
enum ScreenSharingInfo {
    private static let bundleID = "com.apple.ScreenSharing"

    /// This machine's own name (as set in System Settings > General >
    /// About), if a Screen Sharing session is active in either direction —
    /// `nil` the rest of the time, so the switcher's machine-name label
    /// stays hidden by default. Suffixed with "(Sharing)" specifically on
    /// the host side (someone else is viewing/controlling *this* Mac right
    /// now), e.g. "Mac Studio (Sharing)" — that's the direction worth
    /// calling out, since it's the one where this Mac's screen is what's
    /// actually being watched.
    static var activeSessionMachineName: String? {
        guard isClient || isHost else { return nil }
        guard let cfName = SCDynamicStoreCopyComputerName(nil, nil) else { return nil }
        let name = cfName as String
        return isHost ? "\(name) (Sharing)" : name
    }

    /// True while Screen Sharing.app is running here to view another Mac —
    /// doesn't require it to be frontmost.
    private static var isClient: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// True while someone else is viewing/controlling this Mac over Screen
    /// Sharing — detected via `screensharingd`, which launchd registers as
    /// socket-activated on the VNC/`rfb` port (`Disabled` in its static
    /// plist, spawned only when a connection actually arrives on
    /// `Sockets > Listener`). So its presence means an incoming session is
    /// live right now, not merely that Screen Sharing/Remote Management is
    /// turned on in System Settings. The exact daemon name is still internal
    /// (previously `RFBEventHelperd`, which macOS has since retired), so a
    /// future macOS version could rename or replace it again — the
    /// switcher's machine-name label would then just stop appearing for the
    /// host side rather than anything breaking.
    private static var isHost: Bool {
        isProcessRunning(named: "screensharingd")
    }

    /// Whether a process with this exact name (`kinfo_proc.kp_proc.p_comm`)
    /// is currently running, system-wide — checked via `sysctl` rather than
    /// shelling out to `pgrep`, since this can run on every switcher-panel
    /// open.
    private static func isProcessRunning(named targetName: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return false }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procList, &size, nil, 0) == 0 else { return false }

        return procList.contains { proc in
            withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!) == targetName
            }
        }
    }
}
