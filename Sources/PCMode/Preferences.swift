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

    /// `nil` for `.off` — `HotkeyEventTap` treats a nil bucket as "never
    /// matches", so the switcher hotkey is simply never recognized. `.option`
    /// resolves to the `.start` bucket (see `ModifierKeys.swift`) rather than
    /// literal Option, so whichever physical key(s) are configured with the
    /// Start role drive the switcher — by default that's Left Option only,
    /// same as always, but it stays in sync if that assignment changes.
    var bucket: ModifierBucket? {
        switch self {
        case .off: return nil
        case .option: return .start
        case .command: return .command
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
    private let snapShortcutsKey = "snapShortcutsEnabled"
    private let ctrlCVRemapKey = "ctrlCVRemapEnabled"
    private let ctrlCVDenylistKey = "ctrlCVDenylistBundleIDs"
    private let homeEndRemapKey = "homeEndRemapEnabled"

    /// Bundle identifiers exempted from the Control+C/V remap below —
    /// terminal emulators (where Control+C is SIGINT and Control+V can mean
    /// "paste literally") and remote-desktop/VM consoles (where the literal
    /// keystroke needs to reach the far end), seeded in on first launch.
    /// User-editable in the Settings window (`SettingsWindowController`).
    static let defaultCtrlCVDenylist = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.rdc.macos",
        "com.apple.ScreenSharing",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
    ]

    private init() {
        migrateLegacyTriggerPreferenceIfNeeded()
    }

    /// An earlier build stored this under the key "triggerModifier" before
    /// the Off/Option/Command three-way trigger existed. Renaming the key
    /// without this migration meant anyone who'd chosen Command+Tab got
    /// silently reset to the default (Option+Tab) on the next launch, with
    /// no error — exactly the kind of thing that looks like "it just
    /// stopped working." If the old key still has a value and the new one
    /// was never explicitly set, carry the old choice forward instead.
    private func migrateLegacyTriggerPreferenceIfNeeded() {
        let legacyKey = "triggerModifier"
        guard
            defaults.object(forKey: triggerKey) == nil,
            let legacyRaw = defaults.string(forKey: legacyKey)
        else {
            return
        }
        defaults.set(legacyRaw, forKey: triggerKey)
        defaults.removeObject(forKey: legacyKey)
    }

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

    /// Option+Left/Right/Up/Down snap the frontmost window to the left
    /// half, right half, maximize, or minimize — mirroring Windows'
    /// Win+Arrow shortcuts. Defaults on; independent of the window switcher
    /// (see `HotkeyEventTap.handleSnapKey` for how the two coexist when
    /// Option is also the switcher trigger).
    var snapShortcutsEnabled: Bool {
        get { defaults.object(forKey: snapShortcutsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: snapShortcutsKey) }
    }

    /// Control+C / Control+V remapped to Command+C / Command+V, mirroring
    /// Windows' copy/paste shortcuts. Defaults on, like the other shortcuts;
    /// gated per-app by `ctrlCVDenylistBundleIDs` so it doesn't clobber
    /// Control+C-as-SIGINT in terminals etc. See `HotkeyEventTap`.
    var ctrlCVRemapEnabled: Bool {
        get { defaults.object(forKey: ctrlCVRemapKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: ctrlCVRemapKey) }
    }

    /// Apps where Control+C/V passes through unmodified rather than being
    /// remapped — see `defaultCtrlCVDenylist` for why these specific apps
    /// need the literal keystroke. Falls back to that seed list until the
    /// user (or `SettingsWindowController`) explicitly saves an edited one.
    var ctrlCVDenylistBundleIDs: [String] {
        get { defaults.array(forKey: ctrlCVDenylistKey) as? [String] ?? Self.defaultCtrlCVDenylist }
        set { defaults.set(newValue, forKey: ctrlCVDenylistKey) }
    }

    /// Home/End remapped to Command+Left/Right (start/end of line) and
    /// Control+Home/End to Command+Up/Down (start/end of document) —
    /// mirroring Windows' line/document navigation. Defaults on, like the
    /// other shortcuts. See `HotkeyEventTap.remapHomeEnd`.
    var homeEndRemapEnabled: Bool {
        get { defaults.object(forKey: homeEndRemapKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: homeEndRemapKey) }
    }
}

extension Notification.Name {
    static let pcModeTriggerModifierChanged = Notification.Name("PCModeTriggerModifierChanged")
}
