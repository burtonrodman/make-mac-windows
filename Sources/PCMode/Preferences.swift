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
    private let closeWindowShortcutKey = "closeWindowShortcutEnabled"
    private let lockScreenShortcutKey = "lockScreenShortcutEnabled"
    private let perAppKeyRemapKey = "perAppKeyRemapEnabled"
    private let perAppKeyRemapsKey = "perAppKeyRemapsV1"
    private let ctrlF4ClosesTabKey = "ctrlF4ClosesTabEnabled"
    private let ctrlClickMultiSelectKey = "ctrlClickMultiSelectEnabled"
    private let clickThroughActivationKey = "clickThroughActivationEnabled"
    private let screenSharingPassthroughFullScreenOnlyKey = "screenSharingPassthroughFullScreenOnly"

    /// Bundle identifiers exempted from the Control+A/C/S/V remap below —
    /// terminal emulators (where Control+A is readline's "beginning of
    /// line", Control+C is SIGINT, Control+S is XOFF — freezes terminal
    /// output until Control+Q — and Control+V can mean "paste literally")
    /// and remote-desktop/VM consoles (where the literal keystroke needs to
    /// reach the far end), seeded in on first launch. User-editable in the
    /// Settings window (`SettingsWindowController`). VS Code isn't here: it's
    /// covered instead by `fullyExcludedBundleIDs` below, since it needs the
    /// same protection for far more than just this one remap.
    static let defaultCtrlCVDenylist = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.microsoft.rdc.macos",
        "com.apple.ScreenSharing",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
    ]

    /// Bundle identifiers fully excluded from every PCMode keyboard
    /// behavior — the switcher, tap-for-Spotlight, snap shortcuts, and every
    /// remap below — rather than being carved out shortcut-by-shortcut like
    /// `defaultCtrlCVDenylist`. Currently just VS Code: its own keybinding
    /// surface is enormous and user-customizable, and (via its integrated
    /// terminal) the same "needs the literal keystroke" problem that
    /// motivates `defaultCtrlCVDenylist` applies to far more than Control+A/
    /// C/S/V/X there. Not user-editable — a fixed exclusion, unlike
    /// `ctrlCVDenylistBundleIDs`. Users who want Windows-familiar shortcuts
    /// inside VS Code anyway should install the `vscode-windows-keymap`
    /// extension (see repo root) instead — VS Code's own `"when"` context
    /// clauses (`terminalFocus`, `editorTextFocus`) can distinguish the
    /// integrated terminal from the editor exactly, which is more complete
    /// and more reliable than anything PCMode could do from outside via
    /// Accessibility.
    static let fullyExcludedBundleIDs = [
        "com.microsoft.VSCode",
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

    /// Option+Left/Right cycles the frontmost window through the configured
    /// snap zones (see `SnapZones`/`SettingsWindowController`) across every
    /// monitor; Option+Up/Down maximize/minimize — mirroring Windows'
    /// Win+Arrow shortcuts. Defaults on; independent of the window switcher
    /// (see `HotkeyEventTap.handleSnapKey` for how the two coexist when
    /// Option is also the switcher trigger).
    var snapShortcutsEnabled: Bool {
        get { defaults.object(forKey: snapShortcutsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: snapShortcutsKey) }
    }

    /// Control+A/C/S/V/X remapped to Command+A/C/S/V/X, mirroring Windows'
    /// select-all/copy/save/paste/cut shortcuts. Defaults on, like the other
    /// shortcuts; gated per-app by `ctrlCVDenylistBundleIDs` so it doesn't
    /// clobber Control+C-as-SIGINT, Control+S-as-XOFF, etc. in terminals.
    /// See `HotkeyEventTap`. (Named for the two shortcuts this started as —
    /// kept as-is to avoid a settings-migration for what's still one
    /// toggle covering a handful of closely-related keys.)
    var ctrlCVRemapEnabled: Bool {
        get { defaults.object(forKey: ctrlCVRemapKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: ctrlCVRemapKey) }
    }

    /// Apps where Control+A/C/S/V/X passes through unmodified rather than
    /// being remapped — see `defaultCtrlCVDenylist` for why these specific
    /// apps need the literal keystroke. Falls back to that seed list until
    /// the user (or `SettingsWindowController`) explicitly saves an edited
    /// one.
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

    /// Command+F4 closes the focused window, mirroring Windows' Alt+F4 (bound
    /// to Command rather than Option/Start so it doesn't collide with the
    /// switcher/snap/tap-for-Spotlight shortcuts). Defaults on, like the
    /// other shortcuts. See `HotkeyEventTap` / `WindowCloser`.
    var closeWindowShortcutEnabled: Bool {
        get { defaults.object(forKey: closeWindowShortcutKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: closeWindowShortcutKey) }
    }

    /// Start-role-key+L locks the screen, mirroring Windows' Win+L (Left
    /// Option by default; see `ModifierKeys.swift`). Defaults on, like the
    /// other Start-bucket shortcuts. See
    /// `HotkeyEventTap.handleLockScreenKey` / `LockScreenLocker`.
    var lockScreenShortcutEnabled: Bool {
        get { defaults.object(forKey: lockScreenShortcutKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: lockScreenShortcutKey) }
    }

    /// Per-app literal-keystroke remaps — e.g. Chrome's Ctrl+H (History)
    /// rewritten to its native Mac equivalent, Cmd+Y. Opt-in per app rather
    /// than a denylist, since (unlike Control+A/C/S/V/X or Home/End) these
    /// aren't a general editing convention but a specific app's own
    /// shortcut. See `PerAppKeyRemap.swift` for the rule table and
    /// `HotkeyEventTap.remapPerAppShortcut`. Defaults on, like the other
    /// shortcuts.
    var perAppKeyRemapEnabled: Bool {
        get { defaults.object(forKey: perAppKeyRemapKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: perAppKeyRemapKey) }
    }

    /// The active per-app mapping list — seeded from
    /// `PerAppKeyRemaps.defaultProfile` until the user (or
    /// `SettingsWindowController`'s editor) explicitly saves an edited one,
    /// same fallback pattern as `ctrlCVDenylistBundleIDs`. Stored as JSON
    /// rather than a property-list-native type, since each entry is a small
    /// struct (bundle ID + two keystrokes) rather than a single string.
    var perAppKeyRemaps: [PerAppKeyRemap] {
        get {
            guard
                let data = defaults.data(forKey: perAppKeyRemapsKey),
                let decoded = try? JSONDecoder().decode([PerAppKeyRemap].self, from: data)
            else {
                return PerAppKeyRemaps.defaultProfile
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: perAppKeyRemapsKey)
        }
    }

    /// Control+F4 remapped to Command+W, mirroring Windows' Ctrl+F4 (closes
    /// the current tab/document within an app, as distinct from Alt+F4/this
    /// app's Command+F4, which close the whole window). Defaults on, like
    /// the other shortcuts. See `HotkeyEventTap.remapControlF4`.
    var ctrlF4ClosesTabEnabled: Bool {
        get { defaults.object(forKey: ctrlF4ClosesTabKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: ctrlF4ClosesTabKey) }
    }

    /// Control+Click remapped to Command+Click in place, mirroring Windows'
    /// (and most everywhere else's) convention for toggling one item into a
    /// discontiguous multi-selection in a list — Mac's equivalent is
    /// Command+Click. Unlike every other remap in this file, this defaults
    /// **off**: literal Control+Click is macOS's own long-standing
    /// secondary-click ("right-click") substitute, honored by AppKit and by
    /// most Electron/Chromium apps too, not something scoped to a handful of
    /// terminal-like apps — so unlike Control+A/C/S/V/X, there's no sane
    /// denylist here, since nearly *every* app relies on it to some degree.
    /// Turning this on trades that away everywhere in exchange for
    /// Windows-style multi-select; worth it once you know you don't lean on
    /// Ctrl+Click for context menus (e.g. you already have a working
    /// right-click), not a safe default for everyone. See
    /// `HotkeyEventTap.remapControlClick`.
    var ctrlClickMultiSelectEnabled: Bool {
        get { defaults.object(forKey: ctrlClickMultiSelectKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: ctrlClickMultiSelectKey) }
    }

    /// On Windows, clicking an inactive window both activates it *and*
    /// delivers the click. On macOS, activation and click delivery are two
    /// separate questions the clicked app answers for itself
    /// (`NSView.acceptsFirstMouse(with:)`, default `false`) — most non-Apple
    /// apps treat the first click as activation-only, so a second click is
    /// needed to actually press whatever was clicked. When this is on,
    /// PCMode intercepts that first click itself, activates the target
    /// window, and replays the click once the app is frontmost — see
    /// `ClickThroughActivator`. Defaults **off**, like
    /// `ctrlClickMultiSelectEnabled`: it's a systemwide change to how every
    /// click behaves, with no per-app exclusion list, and — being a
    /// swallow-then-synthesize hack rather than anything Apple exposes an
    /// API for — it's inherently less bullet-proof than the keyboard remaps
    /// above.
    var clickThroughActivationEnabled: Bool {
        get { defaults.object(forKey: clickThroughActivationKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: clickThroughActivationKey) }
    }

    /// Whether passthrough to a remote Screen Sharing session (see
    /// `HotkeyEventTap.shouldPassthroughToScreenSharing`) requires Screen
    /// Sharing's window to be in true full-screen mode, or fires whenever
    /// Screen Sharing is simply the frontmost app — windowed included.
    /// Defaults to `false` (passthrough whenever Screen Sharing is
    /// frontmost, windowed or full-screen), since the point of
    /// passthrough — letting the remote Mac's own keystroke handling (its
    /// own PCMode, if it's running that too, or just the OS) see the
    /// switcher-trigger/snap/click-through gestures instead of this Mac
    /// swallowing them for its own local windows — applies just as much to
    /// a windowed Screen Sharing session as a full-screen one, and running
    /// Screen Sharing in a plain window is at least as common as dedicating
    /// a full Space to it. Set `true` to restore the original, more
    /// conservative behavior (full-screen only) if you'd rather keep your
    /// local switcher/snap/click-through active while Screen Sharing is
    /// merely one window among others.
    var screenSharingPassthroughFullScreenOnly: Bool {
        get { defaults.object(forKey: screenSharingPassthroughFullScreenOnlyKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: screenSharingPassthroughFullScreenOnlyKey) }
    }
}

extension Notification.Name {
    static let pcModeTriggerModifierChanged = Notification.Name("PCModeTriggerModifierChanged")
}
