import Cocoa

/// Orchestrates the Option+Tab window switcher: snapshots the window list on
/// the first Tab press, advances the selection on each subsequent Tab press
/// (matching how holding Alt+Tab on Windows keeps cycling), and commits or
/// cancels when Option is released or Escape is pressed.
final class SwitcherController {
    static let shared = SwitcherController()

    private let panel = SwitcherPanel()
    private var windows: [WindowInfo] = []
    private var selectedIndex = 0

    private init() {}

    func start() {
        HotkeyEventTap.shared.onTabDown = { [weak self] reverse in
            self?.handleTab(reverse: reverse)
        }
        HotkeyEventTap.shared.onTriggerReleased = { [weak self] in
            self?.commit()
        }
        HotkeyEventTap.shared.onEscape = { [weak self] in
            self?.cancel()
        }
        HotkeyEventTap.shared.start()
    }

    private func handleTab(reverse: Bool) {
        if !panel.isVisible {
            windows = WindowLister.listWindows()
            guard windows.count > 1 else { return }
            // Index 0 is the current window; the first Tab should land on
            // the next-most-recent one, exactly like Cmd+Tab/Alt+Tab do.
            selectedIndex = reverse ? windows.count - 1 : 1
            panel.show(windows: windows, selectedIndex: selectedIndex)
        } else {
            guard !windows.isEmpty else { return }
            selectedIndex = (selectedIndex + (reverse ? -1 : 1) + windows.count) % windows.count
            panel.updateSelection(selectedIndex)
        }
    }

    private func commit() {
        guard panel.isVisible else { return }
        panel.hide()
        if windows.indices.contains(selectedIndex) {
            WindowActivator.activate(windows[selectedIndex])
        }
        windows = []
    }

    private func cancel() {
        panel.hide()
        windows = []
    }
}
