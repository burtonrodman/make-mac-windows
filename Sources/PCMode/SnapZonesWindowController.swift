import Cocoa

/// A single monitor's zone editor: draws its 1-3 configured zones side by
/// side, each labeled with its real pixel size, and lets the user drag the
/// divider(s) between them to adjust the split, live (with a left/right
/// resize cursor over each divider). Purely a view over
/// `Preferences.snapZoneSplits` for one display — `SnapZonesWindowController`
/// owns the zone-count control and writes a fresh even split into this view
/// whenever the count changes.
private final class SnapZoneStripView: NSView {
    /// How close (in points) a mouseDown has to land to a divider's current
    /// position to start dragging it, rather than being ignored.
    private static let handleHitSlop: CGFloat = 10
    /// Smallest a zone is allowed to shrink to, as a fraction of the strip's
    /// full width — keeps a dragged divider from collapsing a neighboring
    /// zone to nothing (or crossing past the next divider).
    private static let minZoneFraction: CGFloat = 0.08

    private static let zoneColors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange]

    let displayID: CGDirectDisplayID
    /// The real display's zone-bearing size (its `visibleFrame`, in points —
    /// the same space `SnapZones.zones(for:)` slices up), used only to
    /// compute the pixel-size label drawn on each zone; unrelated to this
    /// view's own on-screen size.
    private let screenSize: CGSize
    /// Current split fractions (0-1, strictly increasing), live during a
    /// drag. Committed to `Preferences` only on mouseUp — see `mouseUp`.
    private(set) var splits: [CGFloat]
    /// Called with the final splits once a drag ends.
    var onSplitsCommitted: ((_ splits: [CGFloat]) -> Void)?

    private var draggingDividerIndex: Int?

    init(displayID: CGDirectDisplayID, screenSize: CGSize, splits: [CGFloat]) {
        self.displayID = displayID
        self.screenSize = screenSize
        self.splits = splits
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the splits wholesale (e.g. after the zone-count popup
    /// changes) and redraws — bypasses the drag-commit path since this isn't
    /// a user drag.
    func setSplits(_ newSplits: [CGFloat]) {
        splits = newSplits
        draggingDividerIndex = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let sizeLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]

        let bounds01 = [0.0] + splits.map(Double.init) + [1.0]
        for index in 0 ..< bounds01.count - 1 {
            let startFraction = bounds01[index]
            let endFraction = bounds01[index + 1]
            let x0 = bounds.width * CGFloat(startFraction)
            let x1 = bounds.width * CGFloat(endFraction)
            let zoneRect = NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).insetBy(dx: 3, dy: 3)
            let path = NSBezierPath(roundedRect: zoneRect, xRadius: 6, yRadius: 6)
            let color = Self.zoneColors[index % Self.zoneColors.count]
            color.withAlphaComponent(0.25).setFill()
            path.fill()
            color.setStroke()
            path.stroke()

            // The zone's real pixel footprint — i.e. what the window will
            // actually measure once snapped into it (see
            // `SnapZones.zones(for:)`, which slices this same `screenSize`).
            let pixelWidth = Int((CGFloat(endFraction - startFraction) * screenSize.width).rounded())
            let pixelHeight = Int(screenSize.height.rounded())
            let label = "\(pixelWidth) × \(pixelHeight)"
            let labelSize = label.size(withAttributes: sizeLabelAttributes)
            let labelOrigin = NSPoint(x: zoneRect.midX - labelSize.width / 2, y: zoneRect.midY - labelSize.height / 2)
            label.draw(at: labelOrigin, withAttributes: sizeLabelAttributes)
        }

        NSColor.separatorColor.setFill()
        for split in splits {
            let x = bounds.width * split
            NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8).fill()
        }
    }

    /// Shows a left/right resize cursor over each divider's hit area — the
    /// same tolerance `mouseDown` uses to decide whether a click starts a
    /// drag — so it's clear before the user even clicks that the divider is
    /// draggable. AppKit calls this automatically on hover/frame changes;
    /// `setSplits`/`mouseDragged` additionally invalidate it explicitly
    /// since divider positions can move without either of those.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard bounds.width > 0 else { return }
        for split in splits {
            let x = bounds.width * split
            let rect = NSRect(
                x: x - Self.handleHitSlop, y: 0, width: Self.handleHitSlop * 2, height: bounds.height
            )
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        let fraction = convert(event.locationInWindow, from: nil).x / bounds.width
        let hitSlopFraction = Self.handleHitSlop / bounds.width

        guard
            let nearest = splits.indices.min(by: { abs(splits[$0] - fraction) < abs(splits[$1] - fraction) }),
            abs(splits[nearest] - fraction) <= hitSlopFraction
        else {
            return
        }
        draggingDividerIndex = nearest
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = draggingDividerIndex, bounds.width > 0 else { return }
        NSCursor.resizeLeftRight.set()

        let lowerNeighbor = index == 0 ? 0 : splits[index - 1]
        let upperNeighbor = index == splits.count - 1 ? 1 : splits[index + 1]
        let lowerBound = lowerNeighbor + Self.minZoneFraction
        let upperBound = upperNeighbor - Self.minZoneFraction

        let fraction = convert(event.locationInWindow, from: nil).x / bounds.width
        splits[index] = min(max(fraction, lowerBound), upperBound)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard draggingDividerIndex != nil else { return }
        draggingDividerIndex = nil
        onSplitsCommitted?(splits)
    }
}

/// PCMode's snap-zone editor: one row per connected monitor, each with a
/// 1/2/3 zone-count control and a draggable strip (`SnapZoneStripView`) for
/// adjusting the split between them. This is what `WindowSnapper.cycleZone`
/// reads back via `Preferences.snapZoneSplits`/`SnapZones` when Start+Left/
/// Right steps the frontmost window through every zone on every monitor.
///
/// A plain programmatic `NSWindow` (no nib/storyboard), matching
/// `SettingsWindowController`/`SwitcherPanel`. Kept alive as a singleton so
/// it isn't torn down and rebuilt every time it's opened from the menu.
final class SnapZonesWindowController: NSWindowController {
    static let shared = SnapZonesWindowController()

    private static let padding: CGFloat = 20
    private static let stripHeight: CGFloat = 70

    private let stack = NSStackView()
    private var stripViews: [CGDirectDisplayID: SnapZoneStripView] = [:]
    private var countPopups: [CGDirectDisplayID: NSPopUpButton] = [:]

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snap Zones"
        window.center()
        // Same reasoning as `SettingsWindowController`: an accessory app has
        // no other window to fall back to, so keep this one around instead
        // of rebuilding its view hierarchy from scratch every time it opens.
        window.isReleasedWhenClosed = false

        self.init(window: window)
        buildUI()
    }

    /// Rebuilds the monitor rows from the *current* screen arrangement every
    /// time the window is shown — monitors can be connected/disconnected
    /// between opens, and there's no notification wired up to catch that
    /// while the window is closed.
    func show() {
        rebuildRows()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Snap Zones")
        heading.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "Each monitor is divided into 1-3 left-to-right zones. Start+Left/Right steps " +
                "the focused window through every zone on every monitor, in order — drag a " +
                "divider below to adjust the split.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let outerStack = NSStackView(views: [heading, explanation, stack])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 16
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(outerStack)
        // Padding lives on these outer constraints (see
        // `SettingsWindowController.buildUI` for why not `edgeInsets`).
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.padding),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Self.padding),
            outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.padding),
            outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.padding),
            heading.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            stack.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
        ])
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        stripViews = [:]
        countPopups = [:]

        for screen in NSScreen.screens.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let displayID = SnapZones.displayID(of: screen) else { continue }
            stack.addArrangedSubview(buildRow(for: screen, displayID: displayID))
        }
    }

    private func buildRow(for screen: NSScreen, displayID: CGDirectDisplayID) -> NSView {
        let size = screen.frame.size
        let label = NSTextField(labelWithString:
            "\(screen.localizedName) — \(Int(size.width))×\(Int(size.height))")
        label.font = .systemFont(ofSize: 12, weight: .medium)

        let splits = Preferences.shared.snapZoneSplits(forDisplayID: displayID)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for count in 1 ... SnapZones.maxZonesPerMonitor {
            popup.addItem(withTitle: "\(count) zone\(count == 1 ? "" : "s")")
        }
        popup.selectItem(at: (splits.count + 1) - 1)
        popup.target = self
        popup.action = #selector(zoneCountChanged(_:))
        popup.tag = Int(displayID)
        countPopups[displayID] = popup

        let headerRow = NSStackView(views: [label, popup])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8

        let strip = SnapZoneStripView(displayID: displayID, screenSize: screen.visibleFrame.size, splits: splits)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onSplitsCommitted = { [weak self] newSplits in
            self?.commitSplits(newSplits, forDisplayID: displayID)
        }
        stripViews[displayID] = strip

        let row = NSStackView(views: [headerRow, strip])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: row.widthAnchor),
            strip.widthAnchor.constraint(equalTo: row.widthAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
        ])
        return row
    }

    @objc private func zoneCountChanged(_ sender: NSPopUpButton) {
        let displayID = CGDirectDisplayID(sender.tag)
        let count = sender.indexOfSelectedItem + 1
        let splits = SnapZones.evenSplits(forZoneCount: count)
        commitSplits(splits, forDisplayID: displayID)
        stripViews[displayID]?.setSplits(splits)
    }

    private func commitSplits(_ splits: [CGFloat], forDisplayID displayID: CGDirectDisplayID) {
        Preferences.shared.setSnapZoneSplits(splits, forDisplayID: displayID)
    }
}
