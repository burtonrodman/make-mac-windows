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
            if event.flags.contains(.maskAlternate) { optionTapState.otherKeyPressedDuringHold = true }
            if event.flags.contains(.maskCommand) { commandTapState.otherKeyPressedDuringHold = true }
        }

        if type == .flagsChanged {
            trackModifierTap(
                event: event, mask: .maskAlternate, state: &optionTapState,
                enabled: Preferences.shared.optionTapOpensSpotlight, onTap: onOptionTap
            )
            trackModifierTap(
                event: event, mask: .maskCommand, state: &commandTapState,
                enabled: Preferences.shared.commandTapOpensSpotlight, onTap: onCommandTap
            )

            if let triggerMask = Preferences.shared.switcherTrigger.mask {
                let triggerNowDown = event.flags.contains(triggerMask)
                if triggerIsDown && !triggerNowDown {
                    triggerIsDown = false
                    onTriggerReleased?()
                } else if triggerNowDown {
                    triggerIsDown = true
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, let triggerMask = Preferences.shared.switcherTrigger.mask {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            if keyCode == kVK_Tab, flags.contains(triggerMask) {
                onTabDown?(flags.contains(.maskShift))
                return nil // swallow so the frontmost app never sees it
            }
            // Left/Right arrows cycle the switcher too, mirroring Tab/Shift+Tab,
            // while the trigger modifier is held.
            if keyCode == kVK_LeftArrow, flags.contains(triggerMask) {
                onTabDown?(true)
                return nil
            }
            if keyCode == kVK_RightArrow, flags.contains(triggerMask) {
                onTabDown?(false)
                return nil
            }
            if keyCode == kVK_Escape, triggerIsDown {
                onEscape?()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func trackModifierTap(
        event: CGEvent, mask: CGEventFlags, state: inout TapState, enabled: Bool, onTap: (() -> Void)?
    ) {
        let nowDown = event.flags.contains(mask)
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
