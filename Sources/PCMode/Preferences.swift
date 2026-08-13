import Cocoa

/// Which modifier + Tab combo triggers the per-window switcher, or `.off` to
/// disable that feature entirely (independent of the Command-tap-opens-
/// Spotlight feature below).
///
/// `.option` has no default system binding, so taking it over is clean.
/// `.command` collides with macOS's built-in Cmd+Tab app switcher — PCMode's
/// event tap sits ahead of the Dock's and swallows the keystroke before it
/// gets there, which works in practice (other switcher-replacement apps do
/// the same), but it's a slightly less bullet-proof takeover than Option.
enum SwitcherTrigger: String {
    case off
    case option
    case command

    /// `nil` for `.off` — `HotkeyEventTap` treats a nil mask as "never
    /// matches", so the switcher hotkey is simply never recognized.
    var mask: CGEventFlags? {
        switch self {
        case .off: return nil
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .option: return "Option (⌥) + Tab"
        case .command: return "Command (⌘) + Tab"
        }
    }
}

final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private let triggerKey = "switcherTrigger"
    private let commandTapSpotlightKey = "commandTapOpensSpotlight"
    private let optionTapSpotlightKey = "optionTapOpensSpotlight"

    private init() {}

    var switcherTrigger: SwitcherTrigger {
        get {
            guard
                let raw = defaults.string(forKey: triggerKey),
                let value = SwitcherTrigger(rawValue: raw)
            else {
                return .option
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: triggerKey)
            NotificationCenter.default.post(name: .pcModeTriggerModifierChanged, object: nil)
        }
    }

    /// Tapping Command alone (pressed and released with no other key
    /// pressed while it was held) opens Spotlight — mirroring the Windows
    /// key opening Start. Defaults on since it's the headline feature; can
    /// be switched off independently of the window switcher.
    var commandTapOpensSpotlight: Bool {
        get { defaults.object(forKey: commandTapSpotlightKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: commandTapSpotlightKey) }
    }

    /// Same gesture, Option instead of Command — independent toggle, and
    /// compatible with using Option+Tab as the window-switcher trigger at
    /// the same time (a held Option+Tab always counts as "another key was
    /// pressed", so it never also fires this).
    var optionTapOpensSpotlight: Bool {
        get { defaults.object(forKey: optionTapSpotlightKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: optionTapSpotlightKey) }
    }
}

extension Notification.Name {
    static let pcModeTriggerModifierChanged = Notification.Name("PCModeTriggerModifierChanged")
}
