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
