import Cocoa

/// Model + persistence for snap zones: each monitor is divided into 1-3
/// left-to-right zones — a generalization of the old fixed 50/50 left/right
/// split — independently configurable per display and adjustable in
/// `SettingsWindowController`. This file only knows how to compute zone
/// rectangles from a display's configured split points and where those
/// split points are stored; `WindowSnapper.cycleZone` is what actually
/// moves a window in and out of them.
enum SnapZones {
    /// 1-3 zones per monitor is what's supported today; more would cramp a
    /// real display and hasn't been asked for.
    static let maxZonesPerMonitor = 3

    /// One zone's on-screen rectangle (Cocoa bottom-left-origin coordinates
    /// — the same space as `NSScreen.visibleFrame`), plus which display it
    /// belongs to. Zones are identified by `displayID` rather than by
    /// holding onto an `NSScreen` instance, since `NSScreen.screens` isn't
    /// guaranteed to hand back the same instances across calls.
    struct Zone {
        let displayID: CGDirectDisplayID
        let frame: CGRect
    }

    /// This screen's zone rectangles, left to right, sliced out of its
    /// `visibleFrame` per its configured split points
    /// (`Preferences.snapZoneSplits`). Falls back to a single whole-screen
    /// zone if the display's `NSScreenNumber` can't be read (shouldn't
    /// happen in practice, but leaves the screen usable rather than
    /// zone-less).
    static func zones(for screen: NSScreen) -> [Zone] {
        guard let displayID = displayID(of: screen) else {
            return [Zone(displayID: 0, frame: screen.visibleFrame)]
        }

        let splits = Preferences.shared.snapZoneSplits(forDisplayID: displayID)
        let bounds = [0.0] + splits.map(Double.init) + [1.0]
        let visible = screen.visibleFrame

        return (0 ..< bounds.count - 1).map { index in
            let start = visible.width * CGFloat(bounds[index])
            let end = visible.width * CGFloat(bounds[index + 1])
            let frame = CGRect(
                x: visible.origin.x + start,
                y: visible.origin.y,
                width: end - start,
                height: visible.height
            )
            return Zone(displayID: displayID, frame: frame)
        }
    }

    /// Every screen's zones, in the order Start+Left/Right step through
    /// (see `WindowSnapper.cycleZone`): left-to-right by monitor position,
    /// then left-to-right within each monitor.
    static func allZonesOrdered() -> [Zone] {
        NSScreen.screens
            .sorted { $0.frame.minX < $1.frame.minX }
            .flatMap { zones(for: $0) }
    }

    /// The stable per-display identifier zones and their persisted splits
    /// are keyed by, read off the Cocoa/AX-adjacent `NSScreenNumber` device
    /// description key.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// Even split points for `count` zones — e.g. 3 zones gives `[1/3, 2/3]`.
    /// Used both as the default for a never-configured display and to reset
    /// a display's splits when its zone count changes in the editor.
    static func evenSplits(forZoneCount count: Int) -> [CGFloat] {
        guard count > 1 else { return [] }
        return (1 ..< count).map { CGFloat($0) / CGFloat(count) }
    }
}

extension Preferences {
    private var snapZoneSplitsKey: String { "snapZoneSplits" }

    /// This display's zone split points: fractions (0-1, strictly
    /// increasing) of screen width where one zone ends and the next begins.
    /// An empty array means 1 zone (the whole screen); `[0.5]` means 2 even
    /// zones (today's default, matching the old fixed left/right halves);
    /// `[0.33, 0.66]` means 3 even zones.
    func snapZoneSplits(forDisplayID displayID: CGDirectDisplayID) -> [CGFloat] {
        guard
            let all = UserDefaults.standard.dictionary(forKey: snapZoneSplitsKey) as? [String: [Double]],
            let stored = all[String(displayID)]
        else {
            return SnapZones.evenSplits(forZoneCount: 2)
        }
        return stored.map { CGFloat($0) }
    }

    func setSnapZoneSplits(_ splits: [CGFloat], forDisplayID displayID: CGDirectDisplayID) {
        var all = UserDefaults.standard.dictionary(forKey: snapZoneSplitsKey) as? [String: [Double]] ?? [:]
        all[String(displayID)] = splits.map { Double($0) }
        UserDefaults.standard.set(all, forKey: snapZoneSplitsKey)
    }
}
