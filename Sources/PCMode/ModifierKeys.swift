import Cocoa

/// The physical modifier-key positions PCMode can tell apart, in Mac
/// keyboard order left to right. There's no `.rightControl` case because
/// Apple keyboards (and most third-party ones in Mac mode, including the
/// Logitech K860) have no physical right Control key — the corresponding
/// bottom-right position is Option.
///
/// `CGEventFlags`'s public API (`.maskAlternate`, `.maskControl`, etc.) is
/// device-*independent* — it can't tell left Option from right Option. But
/// the raw flags value underneath also carries the device-*dependent* bits
/// macOS itself uses internally (`NX_DEVICELALTKEYMASK` and friends, from
/// IOLLEvent.h — undocumented but stable, and the same trick tools like
/// Karabiner-Elements and Hammerspoon rely on). `isDown(_:)` reads those
/// bits directly off `CGEventFlags.rawValue`.
enum ModifierSlot: String, CaseIterable {
    case fn
    case leftControl
    case leftOption
    case leftCommand
    case rightCommand
    case rightOption

    /// Device-dependent bit for this slot, or `nil` for `fn` (which has no
    /// left/right variant and is covered by the public `.maskSecondaryFn`
    /// instead).
    private var deviceBit: UInt64? {
        switch self {
        case .fn: return nil
        case .leftControl: return 0x0001 // NX_DEVICELCTLKEYMASK
        case .leftOption: return 0x0020 // NX_DEVICELALTKEYMASK
        case .leftCommand: return 0x0008 // NX_DEVICELCMDKEYMASK
        case .rightCommand: return 0x0010 // NX_DEVICERCMDKEYMASK
        case .rightOption: return 0x0040 // NX_DEVICERALTKEYMASK
        }
    }

    /// Whether this specific physical key is down in the given event flags.
    func isDown(_ flags: CGEventFlags) -> Bool {
        if self == .fn { return flags.contains(.maskSecondaryFn) }
        guard let bit = deviceBit else { return false }
        return flags.rawValue & bit != 0
    }

    /// All bits (device-independent + device-specific) this key contributes
    /// when held — used to strip exactly this key's contribution from a
    /// synthetic event PCMode rewrites in place, without touching unrelated
    /// modifiers (e.g. Shift riding along for a selection).
    var flagBits: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftControl: return [.maskControl, CGEventFlags(rawValue: deviceBit!)]
        case .leftOption: return [.maskAlternate, CGEventFlags(rawValue: deviceBit!)]
        case .leftCommand: return [.maskCommand, CGEventFlags(rawValue: deviceBit!)]
        case .rightCommand: return [.maskCommand, CGEventFlags(rawValue: deviceBit!)]
        case .rightOption: return [.maskAlternate, CGEventFlags(rawValue: deviceBit!)]
        }
    }

    /// Roles this key can be assigned, in the order offered in Settings.
    /// Curated per key rather than the full `ModifierRole` list: `.start`
    /// (the Windows-Start-key bundle) is only ever offered on the two
    /// bottom-left keys, and a role identical to a key's own native
    /// identity (e.g. `.control` on `leftControl`) is left off since
    /// `.system` already means that.
    var allowedRoles: [ModifierRole] {
        switch self {
        case .fn: return [.system, .control]
        case .leftControl: return [.system, .start, .command]
        case .leftOption: return [.system, .start, .control, .command]
        case .leftCommand: return [.system]
        case .rightCommand: return [.system]
        case .rightOption: return [.system, .control]
        }
    }

    /// Ships with today's behavior preserved on the left (Left Option is
    /// still the Start-key), and the actual fix on the right: Right Option
    /// defaults to `.control` instead of joining the Start bundle, so it
    /// never fires window snap / the switcher / tap-for-Spotlight, and
    /// instead powers Control+C/V and Ctrl+Home/End-style doc navigation —
    /// useful for the K860 (and any keyboard without a physical right
    /// Control key) without a global Option/Control swap.
    var defaultRole: ModifierRole {
        switch self {
        case .rightOption: return .control
        case .leftOption: return .start
        default: return .system
        }
    }

    var displayName: String {
        switch self {
        case .fn: return "fn"
        case .leftControl: return "Left Control (⌃)"
        case .leftOption: return "Left Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightOption: return "Right Option (⌥)"
        }
    }
}

/// What a physical modifier key is treated as for the PCMode features that
/// explicitly key off a modifier — the window switcher trigger, tap-alone-
/// opens-Spotlight, window snap, the Control+C/V remap, and the Home/End
/// remap. This is purely internal to those features: it never changes what
/// keystroke reaches other apps on its own (that's still literal Option/
/// Control/Command everywhere else), and it's not a global remap — a key
/// assigned `.control` here doesn't stop being Control for the rest of
/// macOS, it's just also/instead counted as Control for PCMode's own
/// decisions about when to act.
enum ModifierRole: String, CaseIterable {
    /// This key's own native identity — see `ModifierSlot.defaultRole` doc
    /// and `resolvedBucket` for what that means per key.
    case system
    /// The Windows-Start-key bundle: tap-alone opens Spotlight, held+Tab
    /// (or +Left/Right) drives the window switcher, held+Arrow snaps the
    /// frontmost window.
    case start
    /// Feeds the Control+C/V remap and the Control+Home/Control+End
    /// document-navigation branch of the Home/End remap.
    case control
    /// Feeds the Command-flavored switcher trigger and tap-for-Spotlight.
    case command

    var displayName: String {
        switch self {
        case .system: return "System (no special handling)"
        case .start: return "Start key (Spotlight tap, switcher, window snap)"
        case .control: return "Control (Control+C/V, Control+Home/End)"
        case .command: return "Command (switcher, Spotlight tap)"
        }
    }
}

/// The three buckets PCMode's handled shortcuts actually key off. A key
/// with role `.system` resolves into one of these (or none) depending on
/// what it natively is; `.start`/`.control`/`.command` resolve to
/// themselves regardless of which physical key holds them.
enum ModifierBucket {
    case start
    case control
    case command
}

extension ModifierSlot {
    /// Which bucket this slot currently feeds, given its configured role.
    /// `.system` is the only role that depends on the slot itself: Control-
    /// native and Command-native keys already imply their own bucket just
    /// by being themselves, while `fn` and the Option keys imply no bucket
    /// at all — they have to be explicitly assigned `.start`/`.control`/
    /// `.command` to join one, which is what lets Right Option default to
    /// `.control` without also silently becoming a second Start-key.
    func bucket(for role: ModifierRole) -> ModifierBucket? {
        switch role {
        case .start: return .start
        case .control: return .control
        case .command: return .command
        case .system:
            switch self {
            case .leftControl: return .control
            case .leftCommand, .rightCommand: return .command
            case .fn, .leftOption, .rightOption: return nil
            }
        }
    }
}

extension Preferences {
    private var modifierRoleKeyPrefix: String { "modifierRole." }

    /// The role currently assigned to a physical modifier key. Falls back
    /// to `slot.defaultRole` if unset, or if a stored value somehow isn't
    /// in that slot's `allowedRoles` (e.g. an older build's default drifting
    /// out from under a value written before this key existed).
    func role(for slot: ModifierSlot) -> ModifierRole {
        guard
            let raw = UserDefaults.standard.string(forKey: modifierRoleKeyPrefix + slot.rawValue),
            let role = ModifierRole(rawValue: raw),
            slot.allowedRoles.contains(role)
        else {
            return slot.defaultRole
        }
        return role
    }

    func setRole(_ role: ModifierRole, for slot: ModifierSlot) {
        UserDefaults.standard.set(role.rawValue, forKey: modifierRoleKeyPrefix + slot.rawValue)
    }

    /// Whether any currently-held key resolves into the given bucket —
    /// e.g. `isBucketHeld(.start, in: flags)` replaces what used to be a
    /// flat `flags.contains(.maskAlternate)` check, honoring per-key role
    /// reassignment instead of always matching either Option key.
    func isBucketHeld(_ bucket: ModifierBucket, in flags: CGEventFlags) -> Bool {
        ModifierSlot.allCases.contains { slot in
            slot.isDown(flags) && slot.bucket(for: role(for: slot)) == bucket
        }
    }

    /// All configured slots that are currently down and resolve into the
    /// given bucket — used where the caller needs to strip exactly the
    /// contributing key(s)' flag bits from a synthetic event (see
    /// `HotkeyEventTap.remapHomeEnd` / `remapControlCopyPaste`).
    func slotsHeld(inBucket bucket: ModifierBucket, flags: CGEventFlags) -> [ModifierSlot] {
        ModifierSlot.allCases.filter { slot in
            slot.isDown(flags) && slot.bucket(for: role(for: slot)) == bucket
        }
    }
}
