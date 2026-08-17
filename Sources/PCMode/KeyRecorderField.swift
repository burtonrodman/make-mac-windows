import Cocoa

/// A clickable field that captures the next physical keystroke pressed while
/// it's "recording" — used by the per-app mapping editor
/// (`SettingsWindowController`) to capture a shortcut's key code without
/// asking the user to type a symbolic name for it (there's no universal one
/// for keys like F12 or the arrow keys). Modifier-only presses (just
/// pressing Control alone, say) are ignored — recording keeps waiting for an
/// actual key.
///
/// This only reports the key code. Which modifiers apply is a separate,
/// explicit set of checkboxes (and, for a mapping's trigger side, a
/// Left/Right/Either picker per modifier — see
/// `SettingsWindowController.ModifierRow`) rather than whatever happened to
/// be held during capture, since the whole point of that picker is to let
/// the physical side be *edited*, not just recorded once.
final class KeyRecorderField: NSButton {
    /// Fired once a keystroke is captured.
    var onCapture: ((_ keyCode: Int) -> Void)?

    var keyCode: Int? {
        didSet { updateTitle() }
    }

    private var monitor: Any?
    private var isRecording = false {
        didSet { updateTitle() }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopRecording()
    }

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.keyCode = Int(event.keyCode)
            self.onCapture?(Int(event.keyCode))
            self.stopRecording()
            return nil // swallow — don't let it type into the sheet or ding
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func updateTitle() {
        if isRecording {
            title = "Press a key…"
        } else if let keyCode {
            title = KeyCodeNames.name(for: keyCode)
        } else {
            title = "Click to set…"
        }
    }
}
