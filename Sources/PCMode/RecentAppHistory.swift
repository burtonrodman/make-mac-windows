import Cocoa

/// Persists a most-recently-activated list of regular apps' bundle
/// identifiers across launches and quits, so the window switcher can still
/// offer something to Tab to even after every app has been closed — mirrors
/// how Windows' Alt+Tab/Start menu keeps recently used apps around after
/// they've been closed, rather than the switcher simply not appearing (see
/// `WindowLister.listWindows`).
enum RecentAppHistory {
    private static let defaultsKey = "recentAppBundleIdentifiers"
    /// Plenty to cover a few closed apps without the persisted list growing
    /// unbounded.
    private static let maxEntries = 10

    private static var observer: NSObjectProtocol?

    /// Begins recording every regular app the user activates from here on.
    /// Idempotent — call once at launch.
    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.activationPolicy == .regular,
                let bundleID = app.bundleIdentifier
            else { return }
            record(bundleID)
        }
    }

    private static func record(_ bundleID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        ids.removeAll { $0 == bundleID }
        ids.insert(bundleID, at: 0)
        if ids.count > maxEntries {
            ids.removeLast(ids.count - maxEntries)
        }
        UserDefaults.standard.set(ids, forKey: defaultsKey)
    }

    /// Recently activated app bundle identifiers, most-recent-first —
    /// regardless of whether each one is still running.
    static func recentBundleIdentifiers() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }
}
