import Carbon.HIToolbox
import Cocoa

/// Installs a global CGEventTap so PCMode can see (and swallow) the trigger
/// modifier + Tab before it reaches whatever app is frontmost — mirroring how
/// macOS itself intercepts Cmd+Tab. Also detects a bare tap of Option or
/// Command (pressed and released with no other key pressed while held) to
/// open Spotlight, mirroring the Windows key opening Start. Requires
/// Accessibility permission.
///
/// The switcher trigger (Option, Command, or Off — see `Preferences`) is
/// read fresh on every event rather than baked in at `start()` time, so
/// changing it in the status-bar menu takes effect immediately without
/// reinstalling the tap.
///
/// `CGEvent.tapCreate` can succeed even when Accessibility hasn't been
/// granted yet — it just never delivers events, silently, with no error.
/// So `start()` is idempotent/re-callable: `AppDelegate` polls
/// `AXIsProcessTrusted()` and calls `start()` again once it flips to true,
/// tearing down and replacing any prior (possibly inert) tap. That means
/// granting permission takes effect immediately, with no app relaunch
/// required.
final class HotkeyEventTap {
    static let shared = HotkeyEventTap()

    /// A modifier must be released within this long of being pressed, with
    /// no other key pressed in between, to count as a "tap" rather than
    /// either a modifier held for some other shortcut or just resting a
    /// finger on it.
    private static let tapMaxDuration: CFAbsoluteTime = 0.5

    /// Tracks one modifier's press/release cycle for tap-gesture detection.
    private struct TapState {
        var isDown = false
        var downAt: CFAbsoluteTime?
        var otherKeyPressedDuringHold = false
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Window-switcher trigger tracking (Option/Command + Tab).
    private var triggerIsDown = false

    // Bare modifier-tap tracking (independent of the above — see class doc).
    private var optionTapState = TapState()
    private var commandTapState = TapState()

    private(set) var isInstalled = false

    /// Fired on trigger+Tab or trigger+Left/Right arrow (and repeats, from OS
    /// key-repeat, while held). `reverse` is true when Shift is also held,
    /// or the key is the Left arrow.
    var onTabDown: ((_ reverse: Bool) -> Void)?
    /// Fired when the trigger modifier is released — commits the selection.
    var onTriggerReleased: (() -> Void)?
    /// Fired on Escape while the trigger modifier is held — cancels.
    var onEscape: (() -> Void)?
    /// Fired when Option is tapped alone (see `tapMaxDuration`).
    var onOptionTap: (() -> Void)?
    /// Fired when Command is tapped alone (see `tapMaxDuration`).
    var onCommandTap: (() -> Void)?

    /// Reports whether the window-switcher panel is currently showing.
    /// Consulted only when the switcher trigger is the Start bucket (see
    /// `handle(type:event:)`) to resolve the one case where a Start-role-key
    /// +Left/Right could mean either thing: mid trigger+Tab gesture, the
    /// arrows cycle the switcher; otherwise they snap the frontmost window
    /// instead. Set by `SwitcherController`.
    var isSwitcherVisible: (() -> Bool)?
    /// Fired on Start-role-key+Left/Right/Up/Down to act on the frontmost
    /// window — cycle to the previous/next configured snap zone (see
    /// `SnapZones`), maximize, minimize, respectively (Left Option by
    /// default; see `ModifierKeys.swift`). Not fired when the Start bucket
    /// is also the switcher trigger and its panel is currently visible (see
    /// `isSwitcherVisible`).
    var onSnapLeft: (() -> Void)?
    var onSnapRight: (() -> Void)?
    var onSnapMaximize: (() -> Void)?
    var onSnapMinimize: (() -> Void)?
    /// Fired on Command-role-key+F4 — closes the focused window, mirroring
    /// Windows' Alt+F4 (Left/Right Command by default; see
    /// `ModifierKeys.swift`). Bound to Command rather than the Start bucket
    /// so it doesn't collide with Option's tap-for-Spotlight/switcher/snap
    /// duties.
    var onCloseWindow: (() -> Void)?

    private init() {}

    /// (Re)installs the event tap. Safe to call repeatedly — tears down any
    /// existing tap first.
    func start() {
        teardown()

        let eventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { proxy, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let tapSelf = Unmanaged<HotkeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
                    return tapSelf.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            NSLog(
                "[PCMode] Could not create event tap yet (Accessibility permission " +
                "not granted). Will retry automatically once it's granted."
            )
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isInstalled = true
        NSLog("[PCMode] Event tap installed — trigger is \(Preferences.shared.switcherTrigger.displayName).")
    }

    private func teardown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        isInstalled = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that's slow to respond, or on user
        // request (e.g. Ctrl+Option+Cmd+period). Re-enable so a hiccup
        // doesn't permanently kill the switcher until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Any real keypress while a modifier is held disqualifies a "tap"
        // gesture for that modifier — this is what keeps every Cmd+X or
        // Option+X shortcut (including Option/Command+Tab, if that's the
        // switcher's own trigger) from also opening Spotlight when the
        // modifier comes back up.
        if type == .keyDown {
            if Preferences.shared.isBucketHeld(.start, in: event.flags) {
                optionTapState.otherKeyPressedDuringHold = true
            }
            if Preferences.shared.isBucketHeld(.command, in: event.flags) {
                commandTapState.otherKeyPressedDuringHold = true
            }
        }

        if type == .flagsChanged {
            NSLog(
                "[PCMode][debug] flags=0x%llX keyCode=%d slotsDown=%@",
                event.flags.rawValue,
                event.getIntegerValueField(.keyboardEventKeycode),
                ModifierSlot.allCases.filter { $0.isDown(event.flags) }.map(\.rawValue).description
            )
            trackModifierTap(
                event: event, bucket: .start, state: &optionTapState,
                enabled: Preferences.shared.optionTapOpensSpotlight, onTap: onOptionTap
            )
            trackModifierTap(
                event: event, bucket: .command, state: &commandTapState,
                enabled: Preferences.shared.commandTapOpensSpotlight, onTap: onCommandTap
            )

            if let triggerBucket = Preferences.shared.switcherTrigger.bucket {
                let triggerNowDown = Preferences.shared.isBucketHeld(triggerBucket, in: event.flags)
                if triggerIsDown && !triggerNowDown {
                    triggerIsDown = false
                    onTriggerReleased?()
                } else if triggerNowDown {
                    triggerIsDown = true
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            if handleSnapKey(keyCode: keyCode, flags: flags) {
                return nil
            }

            if handleCloseWindowKey(keyCode: keyCode, flags: flags) {
                return nil
            }

            if remapControlShortcuts(keyCode: keyCode, flags: flags, event: event) {
                // Mutated in place to Cmd+A/C/S/V above — pass the same
                // event through rather than swallowing it.
                return Unmanaged.passUnretained(event)
            }

            if remapHomeEnd(keyCode: keyCode, flags: flags, event: event) {
                // Mutated in place to the Cmd+Arrow equivalent above — pass
                // the same event through rather than swallowing it.
                return Unmanaged.passUnretained(event)
            }

            if let triggerBucket = Preferences.shared.switcherTrigger.bucket {
                let triggerHeld = Preferences.shared.isBucketHeld(triggerBucket, in: flags)
                if keyCode == kVK_Tab, triggerHeld {
                    onTabDown?(flags.contains(.maskShift))
                    return nil // swallow so the frontmost app never sees it
                }
                // Left/Right arrows cycle the switcher too, mirroring
                // Tab/Shift+Tab, while the trigger modifier is held.
                if keyCode == kVK_LeftArrow, triggerHeld {
                    onTabDown?(true)
                    return nil
                }
                if keyCode == kVK_RightArrow, triggerHeld {
                    onTabDown?(false)
                    return nil
                }
            }
            if keyCode == kVK_Escape, triggerIsDown {
                onEscape?()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Start-role-key+Left/Right/Up/Down snap the frontmost window (left
    /// half, right half, maximize, minimize) — by default that's Left
    /// Option only (see `ModifierKeys.swift`), so Right Option is free for
    /// whatever it's assigned instead. Returns whether the event was
    /// consumed.
    ///
    /// This only ever collides with the switcher's own arrow-cycling (see
    /// `handle(type:event:)`) when the switcher trigger is *also* the Start
    /// bucket — in that case, whichever behavior applies depends on whether
    /// the switcher panel is already up: mid trigger+Tab gesture, Left/Right
    /// keep cycling it (returns false here, so the trigger-bucket branch
    /// below handles it instead); otherwise they snap.
    private func handleSnapKey(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard
            Preferences.shared.snapShortcutsEnabled,
            Preferences.shared.isBucketHeld(.start, in: flags)
        else { return false }

        let switcherOwnsArrows = Preferences.shared.switcherTrigger == .option && (isSwitcherVisible?() ?? false)
        guard !switcherOwnsArrows else { return false }

        switch keyCode {
        case kVK_LeftArrow: onSnapLeft?()
        case kVK_RightArrow: onSnapRight?()
        case kVK_UpArrow: onSnapMaximize?()
        case kVK_DownArrow: onSnapMinimize?()
        default: return false
        }
        return true
    }

    /// Command-role-key+F4 closes the focused window — mirroring Windows'
    /// Alt+F4, but bound to Command (Left/Right Command by default; see
    /// `ModifierKeys.swift`) rather than the Start bucket, so it doesn't
    /// collide with Option's tap-for-Spotlight/switcher/snap duties.
    /// Returns whether the event was consumed.
    private func handleCloseWindowKey(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard
            Preferences.shared.closeWindowShortcutEnabled,
            keyCode == kVK_F4,
            Preferences.shared.isBucketHeld(.command, in: flags)
        else { return false }

        onCloseWindow?()
        return true
    }

    /// Control+A/C/S/V, remapped to Command+A/C/S/V in place — mirroring
    /// Windows' select-all/copy/save/paste shortcuts. Requires *bare*
    /// Control (no Shift/Option/Command riding along), so it never touches
    /// Ctrl+Shift+C (Inspect Element in every major browser) or any other
    /// Ctrl-based combo. "Control" here means whichever physical key(s) are
    /// currently assigned the `.control` role (see `ModifierKeys.swift`) —
    /// by default Left Control plus Right Option, not necessarily literal
    /// Control. Skipped entirely when the frontmost app is on
    /// `Preferences.ctrlCVDenylistBundleIDs` — terminals need the literal
    /// Control+A (readline's "beginning of line"), Control+C (SIGINT),
    /// Control+S (XOFF — freezes terminal output until Control+Q, a classic
    /// gotcha), and Control+V (raw paste); remote-desktop/VM consoles need
    /// every one of these to reach the far end unaltered. Returns whether
    /// the event was remapped.
    private func remapControlShortcuts(keyCode: Int, flags: CGEventFlags, event: CGEvent) -> Bool {
        guard Preferences.shared.ctrlCVRemapEnabled else { return false }
        guard
            keyCode == kVK_ANSI_A || keyCode == kVK_ANSI_C ||
                keyCode == kVK_ANSI_S || keyCode == kVK_ANSI_V
        else {
            return false
        }

        let controlSlots = Preferences.shared.slotsHeld(inBucket: .control, flags: flags)
        guard !controlSlots.isEmpty else { return false }

        // "Bare" means nothing is left once the contributing key(s)' own
        // bits are stripped away — so Ctrl+Shift+C, Ctrl+Option+C (from some
        // other key riding along), etc. are still left alone.
        var remaining = flags
        for slot in controlSlots { remaining.subtract(slot.flagBits) }
        guard
            !remaining.contains(.maskControl),
            !remaining.contains(.maskCommand),
            !remaining.contains(.maskShift),
            !remaining.contains(.maskAlternate)
        else {
            return false
        }

        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            Preferences.shared.ctrlCVDenylistBundleIDs.contains(bundleID)
        {
            return false
        }

        event.flags = remaining.union(.maskCommand)
        return true
    }

    /// Home/End remapped to Command+Left/Right (start/end of the current
    /// line) and Control+Home/Control+End to Command+Up/Down (start/end of
    /// the whole document) — mirroring Windows, where Home/End are
    /// line-relative and Control+Home/End are document-relative. macOS has
    /// no native meaning for the physical Home/End keys in most apps, but
    /// Command+Left/Right/Up/Down is the standard Mac equivalent everywhere
    /// text editing works (Cocoa text views, and most apps that follow the
    /// platform convention). Shift rides along unchanged so Shift+Home/End
    /// still extends the selection. "Control" here means whichever physical
    /// key(s) are currently assigned the `.control` role (see
    /// `ModifierKeys.swift`), not necessarily literal Control. Returns
    /// whether the event was remapped.
    private func remapHomeEnd(keyCode: Int, flags: CGEventFlags, event: CGEvent) -> Bool {
        guard Preferences.shared.homeEndRemapEnabled else { return false }

        let controlSlots = Preferences.shared.slotsHeld(inBucket: .control, flags: flags)
        let isDocument = !controlSlots.isEmpty
        let newKeyCode: Int
        switch keyCode {
        case kVK_Home: newKeyCode = isDocument ? kVK_UpArrow : kVK_LeftArrow
        case kVK_End: newKeyCode = isDocument ? kVK_DownArrow : kVK_RightArrow
        default: return false
        }

        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(newKeyCode))
        // Strip exactly the contributing key(s)' bits (e.g. Right Option's
        // .maskAlternate + its device bit, if that's what's configured as
        // Control) rather than the fixed .maskControl this used to be —
        // otherwise a repurposed key's own flag would ride along into the
        // synthetic Command+Arrow event.
        var newFlags = flags
        for slot in controlSlots { newFlags.subtract(slot.flagBits) }
        event.flags = newFlags.union(.maskCommand)
        return true
    }

    private func trackModifierTap(
        event: CGEvent, bucket: ModifierBucket, state: inout TapState, enabled: Bool, onTap: (() -> Void)?
    ) {
        let nowDown = Preferences.shared.isBucketHeld(bucket, in: event.flags)
        defer { state.isDown = nowDown }

        if nowDown && !state.isDown {
            state.downAt = CFAbsoluteTimeGetCurrent()
            state.otherKeyPressedDuringHold = false
            return
        }

        guard !nowDown && state.isDown else { return }
        defer { state.downAt = nil }

        guard
            enabled,
            !state.otherKeyPressedDuringHold,
            let downAt = state.downAt,
            CFAbsoluteTimeGetCurrent() - downAt < Self.tapMaxDuration
        else {
            return
        }
        onTap?()
    }
}
