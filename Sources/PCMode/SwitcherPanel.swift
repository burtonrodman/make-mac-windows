import Cocoa

/// The on-screen HUD shown while the trigger modifier is held after
/// trigger+Tab — a translucent strip of live window preview thumbnails, each
/// badged with its app icon and labeled with its own icon + window title,
/// mirroring the visual language of macOS's own Cmd+Tab bar but at
/// per-window granularity, and closer to Windows' Alt+Tab in showing the
/// window's actual contents rather than just its app icon.
final class SwitcherPanel: NSPanel {
    private static let panelCornerRadius: CGFloat = 28
    /// Extra transparent margin around the visible (rounded) card, existing
    /// solely to give `shadowHost`'s manual CALayer shadow (see below) room
    /// to blur into — a CALayer's shadow is clipped to its own window's
    /// frame, unlike `NSWindow`'s native shadow which can paint outside the
    /// window's frame onto the desktop. Comfortably covers `shadowRadius`
    /// (20) plus `shadowOffset`'s vertical push (10) on every side.
    private static let shadowMargin: CGFloat = 44

    /// A single cell's clickable surface — reports its flat index back to
    /// the panel on mouse-down so clicking a window (rather than only
    /// Tab/arrow-key cycling to it) can select and activate it too.
    private final class CellView: NSView {
        var onClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }

    /// All the sizing that scales with the active screen — a scale of 1.0
    /// reproduces the original fixed sizing (tuned by eye on a QHD or larger
    /// display), and everything shrinks together below that. Without this,
    /// the previews stayed a fixed 420pt wide everywhere: fine on a QHD
    /// ultrawide, but 2-3 huge thumbnails on a laptop screen — most commonly
    /// hit viewing over Screen Sharing while the Mac's usual ultrawide
    /// monitors are physically detached and it falls back to a
    /// laptop-sized virtual display.
    private struct Layout {
        let previewWidth: CGFloat
        let previewHeight: CGFloat
        let cellPadding: CGFloat
        let cellCornerRadius: CGFloat
        let badgeSize: CGFloat
        let captionIconSize: CGFloat
        let captionSpacing: CGFloat
        let itemSpacing: CGFloat
        let outerHorizontalInset: CGFloat
        let outerTopInset: CGFloat
        let outerBottomInset: CGFloat
        let outerStackSpacing: CGFloat
        let cellCaptionFontSize: CGFloat
        let machineLabelFontSize: CGFloat
        let recentAppsLabelFontSize: CGFloat

        init(scale: CGFloat) {
            previewWidth = 420 * scale
            previewHeight = 276 * scale
            cellCornerRadius = 24 * scale
            // Floors below keep padding/spacing/text from disappearing
            // entirely at the low end of the scale range rather than
            // shrinking in exact proportion to the thumbnails.
            cellPadding = max(6, 12 * scale)
            badgeSize = max(72, 132 * scale)
            captionIconSize = max(14, 18 * scale)
            captionSpacing = 8 * scale
            itemSpacing = max(8, 16 * scale)
            outerHorizontalInset = max(16, 32 * scale)
            outerTopInset = max(16, 28 * scale)
            outerBottomInset = max(14, 24 * scale)
            outerStackSpacing = max(10, 16 * scale)
            cellCaptionFontSize = max(11, 14 * scale)
            // Deliberately bigger than the per-cell captions — this is the
            // one piece of chrome answering "which physical Mac is this,"
            // so it should read at a glance, not as a footnote.
            machineLabelFontSize = max(18, 24 * scale)
            // A quieter section-header size — sits between the per-cell
            // captions and the machine label rather than competing with
            // either.
            recentAppsLabelFontSize = max(12, 15 * scale)
        }

        /// Estimated non-grid chrome height (outer insets and — while a
        /// Screen Sharing session is active, see `machineLabel` — the
        /// machine-name label above the grid plus its own spacing, and —
        /// when the switcher has no real windows to offer, see
        /// `recentAppsLabel` — the "Recent Apps" header plus its own
        /// spacing) — used to cap the grid's visible height to what actually
        /// fits the screen.
        func chromeHeight(showingMachineLabel: Bool, showingRecentAppsLabel: Bool) -> CGFloat {
            var height = outerTopInset + outerBottomInset
            if showingMachineLabel {
                height += machineLabelFontSize + 8 + outerStackSpacing
            }
            if showingRecentAppsLabel {
                height += recentAppsLabelFontSize + 8 + outerStackSpacing
            }
            return height
        }
    }

    /// Vertical container of row NSStackViews — the grid wraps into
    /// multiple centered rows instead of growing past the screen edge when
    /// there are a lot of windows open.
    private let grid = NSStackView()
    /// Hosts `grid` as its document view so the grid can scroll vertically
    /// once it's taller than fits on the active screen — the width already
    /// wraps to fit (see `windowRows`), but a smaller screen (e.g. a laptop
    /// viewed over Screen Sharing while its usual ultrawide monitors are
    /// detached) can still produce more rows than fit vertically even after
    /// scaling down.
    private let scrollView = NSScrollView()
    /// Names *this* Mac — where this instance of PCMode is actually running
    /// — whenever a Screen Sharing session is active in either direction
    /// (see `ScreenSharingInfo`), so it's obvious which physical Mac you're
    /// typing into once a Screen Sharing window is in the mix. Hidden (and,
    /// per `NSStackView`'s default behavior, taking up no space or spacing)
    /// the rest of the time.
    private let machineLabel = NSTextField(labelWithString: "")
    /// Headers the grid with "Recent Apps" whenever every entry currently
    /// showing is one of `WindowLister`'s windowless-app fallbacks (icon
    /// only, no real window — see `WindowInfo.previewImage`) rather than an
    /// actual window to switch to, so it's clear why the tiles look like a
    /// plain app list instead of the usual live thumbnails. Hidden (and
    /// takes up no space, per `NSStackView`'s default behavior) the rest of
    /// the time.
    private let recentAppsLabel = NSTextField(labelWithString: "")
    /// A translucent wash of the user's System Settings > Appearance >
    /// Accent Color, sitting between the vibrancy blur and everything else —
    /// mirrors how Windows tints its own Alt-Tab UI with the system accent
    /// color, rather than the plain neutral vibrancy macOS's own Cmd+Tab
    /// bar uses. See `updateAccentTint`.
    private let tintView = NSView()
    private let outerStack = NSStackView()
    /// The window's actual root content view — hosts `shadowHost` and
    /// `visualEffect` side by side (not nested) so `visualEffect`'s own
    /// `masksToBounds` (needed to clip its blur/tint to rounded corners)
    /// can't also clip away `shadowHost`'s shadow. See `shadowMargin`.
    private let rootView = NSView()
    /// A plain, unmasked layer-backed view the same size and rounded shape
    /// as `visualEffect`, sitting directly behind it — exists purely to
    /// cast a `CALayer` shadow that actually conforms to the panel's rounded
    /// corners. `NSWindow`'s own automatic shadow (`hasShadow`) infers its
    /// shape from the window's rendered content, but with
    /// `NSVisualEffectView`'s `.behindWindow` blending mode that inference
    /// falls back to the view's plain rectangular frame — the fabled "square
    /// blur around a rounded panel." A manual `shadowPath` sidesteps that
    /// entirely. See `updateShadowPath`.
    private let shadowHost = NSView()
    private var cellViews: [NSView] = []
    private var windows: [WindowInfo] = []
    private var layout = Layout(scale: 1.0)
    private var scrollViewWidthConstraint: NSLayoutConstraint?
    private var scrollViewHeightConstraint: NSLayoutConstraint?
    /// The flat-index range each displayed row spans, in display order —
    /// e.g. `[0..<4, 4..<7]` for a 4-then-3 wrap. Lets `indexMovingVertically`
    /// map Up/Down arrow presses onto the same visual column in the row
    /// above/below.
    private var rowRanges: [Range<Int>] = []

    /// Fired when a cell is clicked, with that window's flat index —
    /// `SwitcherController` wires this up to select and immediately commit,
    /// so clicking a window activates it just like releasing the trigger key
    /// after Tabbing/arrowing to it.
    var onWindowClicked: ((Int) -> Void)?

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
        // The native window shadow is disabled in favor of `shadowHost`'s
        // manual, rounded-corner-aware one — see its doc comment.
        hasShadow = false
        hidesOnDeactivate = false
        // Clickable (see `CellView`/`onWindowClicked`) — unlike macOS's own
        // Cmd+Tab bar, but matching Windows' Alt-Tab, where clicking a
        // window in the switcher activates it.
        ignoresMouseEvents = false
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
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        shadowHost.wantsLayer = true
        shadowHost.layer?.backgroundColor = NSColor.clear.cgColor
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.5
        shadowHost.layer?.shadowRadius = 20
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -10)
        shadowHost.translatesAutoresizingMaskIntoConstraints = false

        rootView.wantsLayer = true

        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = Self.panelCornerRadius
        tintView.layer?.cornerCurve = .continuous
        tintView.layer?.masksToBounds = true
        tintView.translatesAutoresizingMaskIntoConstraints = false

        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = layout.itemSpacing
        // `grid` is sized by hand each rebuild (see `rebuild(windows:screen:)`)
        // to its own fitting size, since it's used as a scroll view's
        // document view rather than an Auto-Layout-managed arranged subview.

        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        machineLabel.font = .systemFont(ofSize: layout.machineLabelFontSize, weight: .bold)
        machineLabel.alignment = .center
        machineLabel.lineBreakMode = .byTruncatingTail
        machineLabel.textColor = .labelColor
        machineLabel.translatesAutoresizingMaskIntoConstraints = false
        machineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        machineLabel.isHidden = true

        recentAppsLabel.stringValue = "Recent Apps"
        recentAppsLabel.font = .systemFont(ofSize: layout.recentAppsLabelFontSize, weight: .semibold)
        recentAppsLabel.alignment = .center
        recentAppsLabel.lineBreakMode = .byTruncatingTail
        recentAppsLabel.textColor = .secondaryLabelColor
        recentAppsLabel.translatesAutoresizingMaskIntoConstraints = false
        recentAppsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recentAppsLabel.isHidden = true

        outerStack.addArrangedSubview(machineLabel)
        outerStack.addArrangedSubview(recentAppsLabel)
        outerStack.addArrangedSubview(scrollView)
        outerStack.orientation = .vertical
        outerStack.alignment = .centerX
        outerStack.spacing = layout.outerStackSpacing
        outerStack.edgeInsets = NSEdgeInsets(
            top: layout.outerTopInset, left: layout.outerHorizontalInset,
            bottom: layout.outerBottomInset, right: layout.outerHorizontalInset
        )
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        // `tintView` sits between the blur and everything else — added
        // first so it paints under `outerStack`, not over it.
        visualEffect.addSubview(tintView)
        visualEffect.addSubview(outerStack)
        // `shadowHost` goes in first so it paints behind `visualEffect`, not
        // over it — see their doc comments. Both are inset from `rootView`
        // by `shadowMargin` and pinned to each other so they always share
        // the exact same rounded rect.
        rootView.addSubview(shadowHost)
        rootView.addSubview(visualEffect)
        let scrollViewWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: 0)
        let scrollViewHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        self.scrollViewWidthConstraint = scrollViewWidthConstraint
        self.scrollViewHeightConstraint = scrollViewHeightConstraint
        NSLayoutConstraint.activate([
            shadowHost.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            shadowHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Self.shadowMargin),
            shadowHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            shadowHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Self.shadowMargin),
            visualEffect.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            visualEffect.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            outerStack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            // Cap the machine label at 80% of the switcher's own width (not
            // just the icon grid's) so a long machine name truncates instead
            // of forcing the panel wider or running edge-to-edge.
            machineLabel.widthAnchor.constraint(lessThanOrEqualTo: visualEffect.widthAnchor, multiplier: 0.8),
            recentAppsLabel.widthAnchor.constraint(lessThanOrEqualTo: visualEffect.widthAnchor, multiplier: 0.8),
            scrollViewWidthConstraint,
            scrollViewHeightConstraint,
        ])

        contentView = rootView
        updateAccentTint()
    }

    func show(windows: [WindowInfo], selectedIndex: Int, machineName: String?) {
        let screen = NSScreen.main
        // Refreshed on every open rather than just once at init, in case the
        // user's picked a different accent color (or flipped Light/Dark
        // Mode, which some accent colors resolve slightly differently
        // under) since the switcher last showed.
        updateAccentTint()
        updateMachineLabel(machineName)
        updateRecentAppsLabel(windows: windows)
        rebuild(windows: windows, screen: screen)
        updateSelection(selectedIndex)
        centerOnActiveScreen(screen)
        orderFrontRegardless()
    }

    /// Tints `tintView` with the current System Settings > Appearance >
    /// Accent Color. A CALayer's `backgroundColor` is a plain `CGColor`
    /// snapshot rather than a live-updating dynamic color (same tradeoff
    /// `updateSelection` already accepts for the cell-highlight color below)
    /// — fine here since this only needs to be current at the moment the
    /// panel opens, not while it's already showing.
    private func updateAccentTint() {
        tintView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
    }

    /// Shows/hides the machine-name label above the grid — see
    /// `ScreenSharingInfo.activeSessionMachineName`, which supplies `name`.
    /// Set before `rebuild(windows:screen:)` runs, since that's what sizes
    /// the panel to fit whichever chrome is currently showing.
    private func updateMachineLabel(_ name: String?) {
        if let name, !name.isEmpty {
            machineLabel.stringValue = name
            machineLabel.isHidden = false
        } else {
            machineLabel.stringValue = ""
            machineLabel.isHidden = true
        }
    }

    /// Shows the "Recent Apps" header whenever `windows` has no real window
    /// to offer at all — every entry is one of `WindowLister`'s
    /// windowless-app fallbacks (`windowID == 0`). A mix of real windows and
    /// fallback entries (the common case — one app happens to have no open
    /// window while others do) doesn't count; the header is only about the
    /// all-fallback case where the grid is really just a recent-apps list.
    private func updateRecentAppsLabel(windows: [WindowInfo]) {
        let isAllRecentApps = !windows.isEmpty && windows.allSatisfy { $0.windowID == 0 }
        recentAppsLabel.isHidden = !isAllRecentApps
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
            // Keep the selection in view as Tab/arrow keys move it past the
            // edge of whatever's currently scrolled into the visible area.
            cellViews[index].scrollToVisible(cellViews[index].bounds)
        }
    }

    /// The flat index landed on by moving up/down one row from `index`,
    /// preserving the same column (clamped to the destination row's width,
    /// for when rows are uneven) and wrapping from the last row back to the
    /// first — mirroring how Tab/Left-Right already wrap around the whole
    /// list. Returns `index` unchanged when there's only one row.
    func indexMovingVertically(from index: Int, down: Bool) -> Int {
        guard
            rowRanges.count > 1,
            let currentRow = rowRanges.firstIndex(where: { $0.contains(index) })
        else {
            return index
        }

        let newRow = (currentRow + (down ? 1 : -1) + rowRanges.count) % rowRanges.count
        let column = index - rowRanges[currentRow].lowerBound
        let targetRow = rowRanges[newRow]
        return min(targetRow.lowerBound + column, targetRow.upperBound - 1)
    }

    /// How much to shrink the base (QHD-tuned) sizing for the given screen.
    /// 1.0 (no shrinking) is kept for anything QHD-sized or larger —
    /// including an ultrawide, since its extra width doesn't need extra
    /// preview size, just more columns. Below that, previews shrink roughly
    /// in step with the screen so a laptop display (commonly what's actually
    /// driving the panel when viewing over Screen Sharing, since the Mac's
    /// own ultrawide monitors are physically detached) gets proportionally
    /// smaller thumbnails instead of the same giant ones wrapped into more
    /// rows.
    private static func scaleFactor(for screen: NSScreen?) -> CGFloat {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 2560, height: 1440)
        let widthScale = visible.width / 2400
        let heightScale = visible.height / 1350
        return min(1.0, max(0.6, min(widthScale, heightScale)))
    }

    private func rebuild(windows: [WindowInfo], screen: NSScreen?) {
        self.windows = windows
        layout = Layout(scale: Self.scaleFactor(for: screen))

        grid.spacing = layout.itemSpacing
        outerStack.spacing = layout.outerStackSpacing
        outerStack.edgeInsets = NSEdgeInsets(
            top: layout.outerTopInset, left: layout.outerHorizontalInset,
            bottom: layout.outerBottomInset, right: layout.outerHorizontalInset
        )
        machineLabel.font = .systemFont(ofSize: layout.machineLabelFontSize, weight: .bold)
        recentAppsLabel.font = .systemFont(ofSize: layout.recentAppsLabelFontSize, weight: .semibold)

        grid.arrangedSubviews.forEach {
            grid.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        cellViews = []
        rowRanges = []
        for row in windowRows(for: windows, screen: screen) {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = layout.itemSpacing

            let rowStart = cellViews.count
            let rowCells = row.enumerated().map { offset, window in
                makeCell(for: window, index: rowStart + offset)
            }
            rowCells.forEach { rowStack.addArrangedSubview($0) }
            cellViews.append(contentsOf: rowCells)
            rowRanges.append(rowStart..<cellViews.count)

            grid.addArrangedSubview(rowStack)
        }

        grid.layoutSubtreeIfNeeded()
        let gridSize = grid.fittingSize
        // The document view of a scroll view is sized by hand, not by Auto
        // Layout — give it its full natural size regardless of how much of
        // that ends up visible through the (possibly shorter) scroll view.
        grid.frame = NSRect(origin: .zero, size: gridSize)

        // Cap how tall the grid's *visible* area gets to whatever fits the
        // active screen, so a lot of wrapped rows scrolls instead of running
        // the panel off the top/bottom.
        let showingMachineLabel = !machineLabel.isHidden
        let showingRecentAppsLabel = !recentAppsLabel.isHidden
        let chromeHeight = layout.chromeHeight(
            showingMachineLabel: showingMachineLabel,
            showingRecentAppsLabel: showingRecentAppsLabel
        )
        let screenHeight = screen?.visibleFrame.height ?? 800
        let maxGridHeight = max(layout.previewHeight, screenHeight * 0.9 - chromeHeight - Self.shadowMargin * 2)
        let visibleGridHeight = min(gridSize.height, maxGridHeight)

        scrollViewWidthConstraint?.constant = gridSize.width
        scrollViewHeightConstraint?.constant = visibleGridHeight

        var newFrame = frame
        // The visible (rounded) card's size, plus `shadowMargin` on every
        // side for `shadowHost`'s shadow to blur into — see its doc comment.
        newFrame.size = NSSize(
            width: max(280, gridSize.width + layout.outerHorizontalInset * 2) + Self.shadowMargin * 2,
            height: max(180, visibleGridHeight + chromeHeight) + Self.shadowMargin * 2
        )
        // `display: true` so the layout below sees the panel's final size
        // immediately rather than on some later run-loop pass.
        setFrame(newFrame, display: true)
        rootView.layoutSubtreeIfNeeded()
        updateShadowPath()
    }

    /// Recomputes `shadowHost`'s shadow shape to match its current
    /// (rounded, `panelCornerRadius`) bounds. A `CALayer`'s `shadowPath`
    /// doesn't auto-track bounds changes the way its other shadow
    /// properties do, so this needs to be re-run by hand whenever the panel
    /// resizes — e.g. a different number of windows/apps between one show
    /// and the next.
    private func updateShadowPath() {
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: shadowHost.bounds,
            cornerWidth: Self.panelCornerRadius,
            cornerHeight: Self.panelCornerRadius,
            transform: nil
        )
    }

    /// Chunks the window list into rows sized to fit within the active
    /// screen's width, so the panel wraps instead of running off-screen when
    /// a lot of windows are open. Once wrapping is needed, rows are balanced
    /// as evenly as possible (e.g. 4+3 for 7 windows) rather than greedily
    /// filling earlier rows to the max and leaving a sparse final row (6+1).
    private func windowRows(for windows: [WindowInfo], screen: NSScreen?) -> [[WindowInfo]] {
        let screenWidth = screen?.visibleFrame.width ?? 1200
        let maxRowWidth = screenWidth * 0.9 - layout.outerHorizontalInset * 2
        let cellWidth = layout.previewWidth + layout.cellPadding * 2

        let maxColumns = max(1, Int((maxRowWidth + layout.itemSpacing) / (cellWidth + layout.itemSpacing)))
        guard windows.count > maxColumns else { return [windows] }

        let rowCount = Int(ceil(Double(windows.count) / Double(maxColumns)))
        let columns = Int(ceil(Double(windows.count) / Double(rowCount)))

        return stride(from: 0, to: windows.count, by: columns).map {
            Array(windows[$0..<min($0 + columns, windows.count)])
        }
    }

    private func makeCell(for window: WindowInfo, index: Int) -> NSView {
        // `container` is what the selection highlight paints onto (see
        // `updateSelection`) — its own corner radius is a touch larger than
        // `content`'s so the highlight reads as a consistent margin around
        // the thumbnail rather than two mismatched rounded rects. It
        // deliberately does *not* mask its bounds, so the app-icon badge can
        // overhang the thumbnail's corner without getting clipped. Also the
        // cell's clickable surface — see `CellView`.
        let container = CellView()
        container.wantsLayer = true
        container.layer?.cornerRadius = layout.cellCornerRadius + layout.cellPadding
        container.layer?.cornerCurve = .continuous
        container.onClick = { [weak self] in self?.onWindowClicked?(index) }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = layout.cellCornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // Live window contents when we have Screen Recording permission;
        // otherwise fall back to just the app icon, scaled up to fill the
        // same cell a thumbnail would (rather than sitting at its native
        // ~128pt size, dwarfed by the surrounding cell).
        let preview = window.previewImage
        imageView.image = preview ?? window.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown

        // Small icon + window title, centered under the thumbnail — mirrors
        // the badge's app icon but names the specific window, since a busy
        // app can have several tiles in view at once with only their titles
        // to tell them apart.
        let captionIcon = NSImageView(image: window.icon)
        captionIcon.translatesAutoresizingMaskIntoConstraints = false

        let captionTitle = NSTextField(labelWithString: window.displayName)
        captionTitle.font = .systemFont(ofSize: layout.cellCaptionFontSize)
        captionTitle.textColor = .labelColor
        captionTitle.lineBreakMode = .byTruncatingTail
        captionTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionTitle.translatesAutoresizingMaskIntoConstraints = false

        let captionRow = NSStackView(views: [captionIcon, captionTitle])
        captionRow.orientation = .horizontal
        captionRow.alignment = .centerY
        captionRow.spacing = 6
        captionRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(imageView)
        container.addSubview(content)
        container.addSubview(captionRow)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: layout.cellPadding),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: layout.cellPadding),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -layout.cellPadding),
            content.widthAnchor.constraint(equalToConstant: layout.previewWidth),
            content.heightAnchor.constraint(equalToConstant: layout.previewHeight),

            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            captionIcon.widthAnchor.constraint(equalToConstant: layout.captionIconSize),
            captionIcon.heightAnchor.constraint(equalToConstant: layout.captionIconSize),

            // Centered rather than stretched to the thumbnail's full width,
            // so a short title doesn't leave the icon stranded off to one
            // side — but capped to that width so a long one truncates
            // instead of widening the cell.
            captionRow.topAnchor.constraint(equalTo: content.bottomAnchor, constant: layout.captionSpacing),
            captionRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            captionRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            captionRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -layout.cellPadding),
        ])

        // Badge the thumbnail with the owning app's icon (bottom-trailing
        // corner, half-overhanging like a Dock/notification badge) so a
        // window is still identifiable by app at a glance. Skipped when
        // there's no real thumbnail, since the fallback *is* the app icon.
        if preview != nil {
            let badge = NSImageView(image: window.icon)
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.wantsLayer = true
            badge.layer?.shadowColor = NSColor.black.cgColor
            badge.layer?.shadowOpacity = 0.5
            badge.layer?.shadowRadius = 2
            badge.layer?.shadowOffset = .zero
            badge.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: layout.badgeSize),
                badge.heightAnchor.constraint(equalToConstant: layout.badgeSize),
                badge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 4),
                badge.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 4),
            ])
        }

        return container
    }

    private func centerOnActiveScreen(_ screen: NSScreen?) {
        // visibleFrame (not frame) so the panel centers within the area not
        // covered by the menu bar/Dock — on a smaller screen those eat a
        // proportionally bigger bite, and the grid height above is already
        // capped against this same visibleFrame.
        guard let screenFrame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        ))
    }
}
