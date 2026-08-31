# PCMode

A menu-bar utility that makes macOS's keyboard, mouse, and window-management
behavior feel more familiar to a long-time Windows user. `PCMode` is a
placeholder product name — rename freely.

## Feature 1: per-window Alt-Tab

macOS's Cmd+Tab cycles between *apps*; Windows' Alt+Tab cycles between
*windows*. PCMode adds the latter:

- Hold **Option (⌥) and press Tab** (configurable to Command instead — see
  below) to pop up a HUD listing every open window, one tile per window
  rather than one per app.
- Keep pressing Tab (or Shift+Tab) while holding the modifier to cycle
  forward/backward.
- Release the modifier to switch to the highlighted window; press Escape to
  cancel.

### Trigger modifier

Click the PCMode menu-bar icon to choose **Off**, **Option+Tab**, or
**Command+Tab** as the trigger.

- **Option+Tab** has no default system binding, so PCMode's takeover is
  clean and reliable.
- **Command+Tab** collides with macOS's built-in application switcher.
  PCMode's event tap sits ahead of the Dock's in the event-delivery chain
  and swallows the keystroke before the system switcher sees it, which works
  in practice — but it's a slightly less bullet-proof takeover than Option.
  If you ever see the native switcher flash briefly, that's the known rough
  edge; switch back to Option+Tab if it bothers you.
- **Off** disables the window switcher entirely, independent of the
  Command/Option-tap-opens-Spotlight feature below.

## Feature 2: tap a modifier alone to open Spotlight

On Windows, tapping the Windows key alone opens Start. PCMode mirrors this:
tapping **Option** or **Command** alone — pressed and released within half a
second, with no other key pressed while it was held — opens Spotlight.
Holding either as part of an actual shortcut (Cmd+C, Option+Tab, etc.) never
triggers it, since any other keypress during the hold disqualifies the tap.
Each modifier's tap-to-Spotlight behavior has its own on/off toggle in the
menu-bar menu, independent of the window-switcher trigger — e.g. you can use
Option+Tab to switch windows *and* have a bare tap of Option open Spotlight;
the two never conflict because switching always involves pressing Tab too.

Implemented in `SpotlightOpener.swift` by simulating Spotlight's default
shortcut, Cmd+Space — there's no public API to invoke it directly, so this
won't do anything if you've changed Spotlight's shortcut in System Settings
> Keyboard > Keyboard Shortcuts > Spotlight.

### How it works

- A `CGEventTap` (`Sources/PCMode/HotkeyEventTap.swift`) watches for the
  chosen modifier + Tab globally and swallows it before the frontmost app
  sees it.
- `WindowLister` (`WindowInfo.swift`) snapshots on-screen windows across all
  apps via `CGWindowListCopyWindowInfo`, filtering down to real user
  windows. List order approximates most-recently-used, since activating a
  window brings it to the front of the window-server's z-order.
- `SwitcherPanel` shows a translucent HUD (icon + window title per tile),
  mirroring the visual language of macOS's own Cmd+Tab bar.
- `WindowActivator` raises the chosen window specifically (not just its
  owning app) via the Accessibility API, so switching works even between two
  windows of the same app.

### Known v1 limitations

- Minimized windows aren't included yet (`CGWindowListCopyWindowInfo` only
  reports on-screen windows). Windows' Alt-Tab includes minimized windows
  too — natural follow-up, not blocking v1.
- Window ordering is a z-order approximation of MRU, not a tracked
  activation history.
- Single-monitor-aware centering (HUD centers on `NSScreen.main`).

## Feature 4: Control+C / Control+X / Control+V copy, cut, and paste

Windows copies, cuts, and pastes with Ctrl+C / Ctrl+X / Ctrl+V; the Mac
equivalents are Cmd+C / Cmd+X / Cmd+V. PCMode remaps the former to the
latter almost everywhere — but "almost" is load-bearing here, since Control
isn't an unclaimed modifier the way Option was for the window switcher:

- **Terminals** (Terminal.app, iTerm2, etc.) rely on the literal Ctrl+C as
  the interrupt signal (SIGINT) and sometimes Ctrl+V for a raw/literal paste
  — remapping those would break running processes, not just muscle memory.
  Ctrl+X has no special terminal meaning, but rides along on the same
  exclusion list for consistency.
- **Remote-desktop and VM consoles** (Microsoft Remote Desktop, Screen
  Sharing, Parallels, VMware Fusion) need the literal keystroke to reach the
  guest OS/remote session, which may have its own idea of what Ctrl+C means.

So the remap is skipped for any app on an exclusion list (seeded with the
apps above, plus a few more terminal emulators), editable from the menu-bar
icon's **Manage Excluded Apps…** window (`SettingsWindowController.swift`)
— add or remove apps there, or reset to the built-in defaults.

The remap only fires for *bare* Control+C/X/V (no Shift/Option/Command
riding along), so it never touches Ctrl+Shift+C — Inspect Element in every
major browser — or any other Ctrl-based shortcut. Toggle the whole feature
on/off from the menu-bar icon, independent of the exclusion list.

### VS Code: fully excluded — use the companion keymap extension instead

Apps that host more than one kind of view under one bundle ID — most
notably VS Code, whose editor and integrated terminal are the same process
— can't be split by a simple app-level exclusion list, since the event tap
only knows which *app* is frontmost, not which view inside it has focus.
Rather than pick one side of that tradeoff, VS Code is fully excluded from
every PCMode keystroke remap (Control+A/C/S/V/X, Home/End, and
Control+F4-closes-tab; the window switcher, tap-for-Spotlight, and snap
shortcuts are unaffected, since none of those collide with anything VS Code
itself binds) — see `Preferences.fullyExcludedBundleIDs`.

Windows-style shortcuts *inside* VS Code are handled instead by
[`vscode-windows-keymap/`](vscode-windows-keymap/), a small companion VS
Code extension (same idea as the "Sublime Text Keymap" or "Atom Keymap"
extensions) rather than a PCMode feature. It rebinds the ~100 commands
Windows and macOS default to different keys for — Quick Open, cut/copy/
paste, multi-cursor, panel toggles, editor-group navigation, and more —
using VS Code's own `"when"` context clauses (`terminalFocus`,
`editorTextFocus`) to distinguish the integrated terminal from the editor
*exactly*, which is more complete and more reliable than anything PCMode
could do from outside via Accessibility. See that extension's README for
install steps and known OS-level caveats (a few Windows shortcuts collide
with macOS's own Mission Control bindings and can't be fixed from within
VS Code).

## Feature 5: Control+Click for list multi-select (off by default)

Windows' (and most other platforms') convention for toggling one item into
a discontiguous multi-selection in a list is Ctrl+Click; the Mac equivalent
is Cmd+Click. PCMode can remap the former to the latter, system-wide, the
same way it does Control+A/C/S/V/X — but unlike that remap, **this one
defaults off**, and there's no per-app exclusion list, because the
tradeoff is a different shape entirely: literal Control+Click is macOS's
own long-standing secondary-click ("right-click") substitute, honored by
AppKit and by most Electron/Chromium apps too — not a handful of
terminal-like apps that need carving out, but something close to *every*
app to some degree. Turning this on trades away Ctrl+Click-as-right-click
everywhere in exchange for Windows-style multi-select; worth it once you
know you don't lean on Ctrl+Click for context menus (most people with a
working right-click already don't), but not a safe thing to turn on by
default the way the keyboard remaps are. Toggle it from the menu bar's
"List Multi-Select" section — see `Preferences.ctrlClickMultiSelectEnabled`
and `HotkeyEventTap.remapControlClick`.

## Required permissions

PCMode needs two permissions, both requested automatically on first launch:

- **Accessibility** (System Settings > Privacy & Security > Accessibility)
  to install the global event tap and to raise windows belonging to other
  apps. PCMode polls in the background and installs the event tap the
  moment this is granted — no relaunch needed.
- **Screen Recording** (System Settings > Privacy & Security > Screen
  Recording) to read the *real* window titles of other apps' windows.
  Since macOS 10.15, `CGWindowListCopyWindowInfo`'s title field comes back
  empty for windows PCMode doesn't own unless it also holds this permission
  — without it, the switcher caption falls back to showing just the app
  name. Unlike Accessibility, this one typically **does** need a full quit
  and relaunch of PCMode to take effect after granting it.

## Building & running

Requires Xcode/Swift toolchain (developed against Swift 6.3 / Xcode 26).

```sh
./scripts/run.sh     # builds dist/PCMode.app and opens it
```

or just build without launching:

```sh
./scripts/build.sh
```

The app is a background "agent" (no dock icon); control it from its menu-bar
icon. `LSUIElement` is set in the generated `Info.plist`.

`scripts/build.sh` signs the app with a local self-signed identity, **"PCMode
Dev Signing"**, rather than ad-hoc (`--sign -`). Ad-hoc signatures are
recomputed on every rebuild, which makes macOS treat each rebuild as a brand
new, never-approved app and silently stop delivering events to it — the
event tap installs without error, it just never fires. Signing with a
stable identity anchors the app's designated requirement to the
certificate's fingerprint instead of the binary's hash, so the Accessibility
grant survives rebuilds. If you're setting this up on a new machine, the
one-time certificate creation commands are in a comment at the top of that
step in `build.sh`. If PCMode ever seems to stop responding to its hotkey
after a change, check `codesign -dvvv dist/PCMode.app` for `Signature=adhoc`
before assuming the code itself is broken.

## Roadmap

This repo is meant to grow into a broader "make my Mac feel like Windows"
toolkit — keyboard remapping, mouse behavior tweaks, and window-snapping —
beyond this first window-switching feature.
