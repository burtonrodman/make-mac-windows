import Carbon.HIToolbox
import Cocoa

/// Which physical side(s) of a modifier key satisfy a per-app mapping's
/// trigger chord. Deliberately separate from `ModifierKeys.swift`'s
/// `ModifierSlot`/`ModifierRole` system: that exists so a handful of
/// PCMode-owned shortcuts (the switcher, tap-for-Spotlight, window snap,
/// Control+A/C/S/V) can have their *physical key* reassigned while keeping
/// the same behavior. A per-app mapping is the opposite shape — matching one
/// literal keystroke a specific app already expects — so it names a side
/// directly (including `.both`, for "either Control key") instead of going
/// through a reassignable role.
enum ModifierSide: String, Codable, CaseIterable {
    case left
    case right
    case both

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Either"
        }
    }
}

/// One base modifier + side requirement in a per-app mapping's trigger
/// chord — e.g. "Control, either side" for Chrome's Ctrl+H.
struct ModifierRequirement: Hashable, Codable {
    /// Only base modifiers PCMode's event tap can already see reliably.
    /// (No `.fn`: it has no left/right, and doesn't carry the same
    /// "device-independent mask + device bit" shape as the other four.)
    enum Base: String, Codable, CaseIterable {
        case control, option, command, shift

        var displayName: String {
            switch self {
            case .control: return "Control"
            case .option: return "Option"
            case .command: return "Command"
            case .shift: return "Shift"
            }
        }

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .command: return "⌘"
            case .shift: return "⇧"
            }
        }

        /// The device-*independent* mask this base modifier contributes —
        /// used to confirm it's held at all, and (in
        /// `PerAppKeyRemap.matchesModifiers`) to check the trigger chord is
        /// bare.
        var publicMask: CGEventFlags {
            switch self {
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .command: return .maskCommand
            case .shift: return .maskShift
            }
        }
    }

    var base: Base
    var side: ModifierSide

    var publicMask: CGEventFlags { base.publicMask }

    /// Device-dependent bit(s) for the requested side(s) — from IOLLEvent.h's
    /// `NX_DEVICE*KEYMASK` family (undocumented but stable; the same trick
    /// `ModifierSlot` relies on for its own left/right detection). `.both`
    /// ORs the left and right bits together so either physical key
    /// satisfies the requirement.
    private var deviceBits: UInt64 {
        switch (base, side) {
        case (.control, .left): return 0x0001 // NX_DEVICELCTLKEYMASK
        case (.control, .right): return 0x2000 // NX_DEVICERCTLKEYMASK
        case (.control, .both): return 0x0001 | 0x2000
        case (.shift, .left): return 0x0002 // NX_DEVICELSHIFTKEYMASK
        case (.shift, .right): return 0x0004 // NX_DEVICERSHIFTKEYMASK
        case (.shift, .both): return 0x0002 | 0x0004
        case (.command, .left): return 0x0008 // NX_DEVICELCMDKEYMASK
        case (.command, .right): return 0x0010 // NX_DEVICERCMDKEYMASK
        case (.command, .both): return 0x0008 | 0x0010
        case (.option, .left): return 0x0020 // NX_DEVICELALTKEYMASK
        case (.option, .right): return 0x0040 // NX_DEVICERALTKEYMASK
        case (.option, .both): return 0x0020 | 0x0040
        }
    }

    /// Whether this requirement is currently held — the public mask (so
    /// "Control" is reported at all) *and* one of the requested side's
    /// device-dependent bits (so `.left`/`.right` actually discriminate,
    /// rather than matching whichever physical key happens to be down).
    func isSatisfied(by flags: CGEventFlags) -> Bool {
        flags.contains(publicMask) && flags.rawValue & deviceBits != 0
    }

    /// "⌃", "⌃L", or "⌃R" — used by the Settings editor's mapping list.
    var glyph: String {
        switch side {
        case .both: return base.symbol
        case .left: return "\(base.symbol)L"
        case .right: return "\(base.symbol)R"
        }
    }
}

/// One per-app keyboard remap: a literal keystroke (key code + a bare set of
/// modifier requirements — no other Control/Option/Command/Shift may also be
/// held) in a specific app, rewritten to a different keystroke before the
/// app ever sees it. Unlike PCMode's other remaps (Control+A/C/S/V,
/// Home/End), which apply everywhere except a denylist, these are opt-in per
/// app: a Windows-style shortcut a specific app kept instead of adopting the
/// native Mac equivalent.
///
/// User-editable (add/edit/remove) in the Settings window — see
/// `Preferences.perAppKeyRemaps` for how the active list is persisted, and
/// `PerAppKeyRemaps.defaultProfile` for what it's seeded with on first
/// launch.
struct PerAppKeyRemap: Codable, Equatable {
    var bundleID: String
    var fromKeyCode: Int
    var fromModifiers: [ModifierRequirement]
    var toKeyCode: Int
    /// Just the base modifiers for the synthesized event — unlike
    /// `fromModifiers`, the outgoing keystroke has no need to fake a
    /// specific physical side, since nothing downstream distinguishes them.
    var toModifiers: [ModifierRequirement.Base]

    /// Plain device-independent flags for the synthesized event.
    var toFlags: CGEventFlags {
        toModifiers.reduce(into: CGEventFlags()) { $0.formUnion($1.publicMask) }
    }

    /// Whether `flags` is an exact (bare) match for `fromModifiers` — every
    /// listed requirement satisfied, and no other Control/Option/Command/
    /// Shift bit riding along that isn't accounted for.
    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        let relevant: [CGEventFlags] = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let expected = Set(fromModifiers.map(\.publicMask.rawValue))
        let present = Set(relevant.filter { flags.contains($0) }.map(\.rawValue))
        guard present == expected else { return false }
        return fromModifiers.allSatisfy { $0.isSatisfied(by: flags) }
    }

    /// Canonical Mac modifier order (⌃⌥⇧⌘), regardless of storage order —
    /// used by both description strings below.
    private static func ordered(_ bases: [ModifierRequirement.Base]) -> [ModifierRequirement.Base] {
        let order: [ModifierRequirement.Base] = [.control, .option, .shift, .command]
        return order.filter { bases.contains($0) }
    }

    /// "⌃H" / "F12" style summary of the trigger chord, for the Settings
    /// mapping list.
    var fromDescription: String {
        let byBase = Dictionary(uniqueKeysWithValues: fromModifiers.map { ($0.base, $0) })
        let glyphs = Self.ordered(fromModifiers.map(\.base)).compactMap { byBase[$0]?.glyph }
        return glyphs.joined() + KeyCodeNames.name(for: fromKeyCode)
    }

    /// "⌘⌥I" style summary of the target chord.
    var toDescription: String {
        Self.ordered(toModifiers).map(\.symbol).joined() + KeyCodeNames.name(for: toKeyCode)
    }
}

enum PerAppKeyRemaps {
    /// The set of per-app remaps PCMode ships with — seeds
    /// `Preferences.perAppKeyRemaps` on first launch, and what "Reset to
    /// Defaults" in Settings restores. Windows-style shortcuts specific apps
    /// kept as-is on the Mac, rewritten here to each app's own native Mac
    /// equivalent. Grouped by app with a `// MARK:` as this list grows.
    static let defaultProfile: [PerAppKeyRemap] = [
        // MARK: - Google Chrome

        // Ctrl+H ("show History" on Windows) → Cmd+Y (Chrome's own Mac
        // shortcut for History).
        PerAppKeyRemap(
            bundleID: "com.google.Chrome",
            fromKeyCode: kVK_ANSI_H,
            fromModifiers: [ModifierRequirement(base: .control, side: .both)],
            toKeyCode: kVK_ANSI_Y,
            toModifiers: [.command]
        ),

        // F12 (opens Developer Tools on Windows) → Option+Command+I
        // (Chrome's own Mac shortcut for Developer Tools). Bare F12 — no
        // modifier requirements — so `fromModifiers` is empty.
        PerAppKeyRemap(
            bundleID: "com.google.Chrome",
            fromKeyCode: kVK_F12,
            fromModifiers: [],
            toKeyCode: kVK_ANSI_I,
            toModifiers: [.command, .option]
        ),

        // F5 (refresh on Windows) → Cmd+F5. Bare F5 — no modifier
        // requirements.
        PerAppKeyRemap(
            bundleID: "com.google.Chrome",
            fromKeyCode: kVK_F5,
            fromModifiers: [],
            toKeyCode: kVK_F5,
            toModifiers: [.command]
        ),

        // Ctrl+F5 (hard refresh on Windows) → Cmd+Shift+R (Chrome's own Mac
        // shortcut for Reload ignoring cache).
        PerAppKeyRemap(
            bundleID: "com.google.Chrome",
            fromKeyCode: kVK_F5,
            fromModifiers: [ModifierRequirement(base: .control, side: .both)],
            toKeyCode: kVK_ANSI_R,
            toModifiers: [.command, .shift]
        ),
    ]
}
