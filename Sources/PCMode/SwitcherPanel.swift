import Cocoa

/// The on-screen HUD shown while the trigger modifier is held after
/// trigger+Tab — a translucent strip of app icons plus a caption calling out
/// the currently selected window's title, mirroring the visual language of
/// macOS's own Cmd+Tab bar (icons + a single caption for the selection)
/// but at per-window granularity.
final class SwitcherPanel: NSPanel {
    private static let iconSize: CGFloat = 128
    private static let cellPadding: CGFloat = 1
    private static let panelCornerRadius: CGFloat = 28
    // macOS's own app icon artwork is already a squircle at roughly 22% of
    // its size (128 * 0.2237 ≈ 28.6) — matching that here, rather than a
    // tighter/boxier radius, is what makes the highlight look like it's
    // hugging the icon's actual shape instead of a mismatched rounded rect.
    private static let cellCornerRadius: CGFloat = 28
    private static let itemSpacing: CGFloat = 16
    private static let outerHorizontalInset: CGFloat = 32

    /// Vertical container of row NSStackViews — the grid wraps into
    /// multiple centered rows instead of growing past the screen edge when
    /// there are a lot of windows open.
    private let grid = NSStackView()
    private let captionLabel = NSTextField(labelWithString: "")
    private var cellViews: [NSView] = []
    private var windows: [WindowInfo] = []

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        // Let the panel's vibrancy track System Settings > Appearance
        // (Light/Dark/Auto) rather than pinning one look.
        appearance = nil

        let visualEffect = NSVisualEffectView()
        // .hudWindow (volume/brightness-style HUD) always renders dark,
        // regardless of system appearance, and .fullScreenUI reads too
        // opaque/frosted. .menu is closer to the native Cmd+Tab switcher's
        // glassier, more see-through look, and still tracks Light/Dark Mode.
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = Self.panelCornerRadius
        // .continuous is the smooth "squircle" curve macOS uses for its own
        // rounded chrome (Dock, Control Center, notifications) instead of a
        // plain circular-arc corner.
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true

        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = Self.itemSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .systemFont(ofSize: 14, weight: .medium)
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.textColor = .labelColor
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let outerStack = NSStackView(views: [grid, captionLabel])
        outerStack.orientation = .vertical
        outerStack.alignment = .centerX
        outerStack.spacing = 16
        outerStack.edgeInsets = NSEdgeInsets(
            top: 28, left: Self.outerHorizontalInset, bottom: 24, right: Self.outerHorizontalInset
        )
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            outerStack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            // Cap the caption at 80% of the switcher's own width (not just
            // the icon grid's) so a long title truncates instead of forcing
            // the panel wider or running edge-to-edge.
            captionLabel.widthAnchor.constraint(lessThanOrEqualTo: visualEffect.widthAnchor, multiplier: 0.8),
        ])

        contentView = visualEffect
    }

    func show(windows: [WindowInfo], selectedIndex: Int) {
        rebuild(windows: windows)
        updateSelection(selectedIndex)
        centerOnActiveScreen()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    func updateSelection(_ index: Int) {
        for (i, cell) in cellViews.enumerated() {
            cell.layer?.backgroundColor = i == index
                ? NSColor.systemGray.withAlphaComponent(0.35).cgColor
                : NSColor.clear.cgColor
        }
        if windows.indices.contains(index) {
            captionLabel.stringValue = caption(for: windows[index])
        }
    }

    /// "AppName — Window Title", falling back to just the app name when the
    /// window has no title of its own (common for single-window utilities,
    /// or when Screen Recording permission hasn't been granted — see
    /// `AppDelegate.requestScreenRecordingPermissionIfNeeded`). Titles that
    /// already start with the app name (Terminal-style: "Terminal —
    /// make-mac-windows — ...") are shown as-is rather than doubling it up.
    private func caption(for window: WindowInfo) -> String {
        let title = window.title
        guard !title.isEmpty else { return window.ownerName }
        guard title != window.ownerName, !title.hasPrefix(window.ownerName) else {
            return title
        }
        return "\(window.ownerName) — \(title)"
    }

    private func rebuild(windows: [WindowInfo]) {
        self.windows = windows

        grid.arrangedSubviews.forEach {
            grid.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        cellViews = []
        for row in windowRows(for: windows) {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = Self.itemSpacing

            let rowCells = row.map(makeCell)
            rowCells.forEach { rowStack.addArrangedSubview($0) }
            cellViews.append(contentsOf: rowCells)

            grid.addArrangedSubview(rowStack)
        }

        contentView?.layoutSubtreeIfNeeded()

        var newFrame = frame
        newFrame.size = NSSize(
            width: max(280, grid.fittingSize.width + Self.outerHorizontalInset * 2),
            height: max(180, grid.fittingSize.height + 88)
        )
        setFrame(newFrame, display: false)
    }

    /// Chunks the window list into rows sized to fit within the active
    /// screen's width, so the panel wraps instead of running off-screen when
    /// a lot of windows are open.
    private func windowRows(for windows: [WindowInfo]) -> [[WindowInfo]] {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1200
        let maxRowWidth = screenWidth * 0.9 - Self.outerHorizontalInset * 2
        let cellWidth = Self.iconSize + Self.cellPadding * 2

        let columns = max(1, Int((maxRowWidth + Self.itemSpacing) / (cellWidth + Self.itemSpacing)))

        return stride(from: 0, to: windows.count, by: columns).map {
            Array(windows[$0..<min($0 + columns, windows.count)])
        }
    }

    private func makeCell(for window: WindowInfo) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cellCornerRadius
        container.layer?.cornerCurve = .continuous

        let imageView = NSImageView(image: window.icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.cellPadding),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.cellPadding),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.cellPadding),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.cellPadding),
            imageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            imageView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        return container
    }

    private func centerOnActiveScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        setFrameOrigin(NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        ))
    }
}
