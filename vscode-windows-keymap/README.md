# Windows Keymap (PCMode)

Windows-style keyboard shortcuts for VS Code on macOS — the companion
extension to [PCMode](https://github.com/burtonrodman/make-mac-windows),
same idea as the "Sublime Text Keymap" or "Atom Keymap" extensions.

PCMode remaps a lot of Mac keyboard behavior system-wide to feel more like
Windows, but it fully excludes VS Code from that (see the main repo's
README) — an OS-level event tap can't tell VS Code's editor apart from its
own integrated terminal, and guessing wrong there means either breaking
Ctrl+C-as-SIGINT in the terminal or never getting the remap in the editor.

VS Code's own keybinding system doesn't have that problem: its `"when"`
context clauses (`terminalFocus`, `editorTextFocus`, `terminalTextSelected`)
know exactly where focus is, from inside the app. So this extension does
the same job VS Code's own Windows build does for itself — rebinding every
command whose default keybinding differs between Windows and macOS to its
Windows chord — instead of asking PCMode to guess from the outside.

## What it does

Rebinds ~100 commands to their Windows-default keystroke: Quick Open,
cut/copy/paste/select-all, multi-cursor and column selection, panel
toggles (Explorer, Search, Debug, Extensions, …), editor-group navigation,
folding, find/replace, and the integrated terminal's own copy/paste/scroll
shortcuts.

Shortcuts that are already identical on both platforms (most F-keys,
Alt+Up/Down to move a line, Cmd/Ctrl+`  for the terminal, etc.) are left
alone — see `package.json`'s `contributes.keybindings` for the full list,
grouped by section to match [Microsoft's own keyboard shortcut
reference](https://aka.ms/vscodekeybindings).

The integrated terminal's Ctrl+C and Ctrl+V mirror Windows' actual
behavior exactly: Ctrl+C copies only when text is selected, and otherwise
falls through as literal SIGINT (so `git commit` still stops on Ctrl+C);
Ctrl+V always pastes, which does shadow readline's rarer "quoted insert"
binding — same tradeoff Windows itself makes.

## Install

**From a local build (no Marketplace publishing needed):**

```sh
cd vscode-windows-keymap
npx @vscode/vsce package
code --install-extension windows-keymap-0.1.0.vsix
```

Reload VS Code (Cmd+Shift+P → "Developer: Reload Window") afterward.

**To uninstall:** Extensions view → search "Windows Keymap" → Uninstall.

## Known caveats

A handful of Windows shortcuts collide with macOS shortcuts that live
*outside* VS Code, at the OS level — no app, including this one, can
override these from a keybindings contribution:

- **Ctrl+Up / Ctrl+Down** are Mission Control/Spaces shortcuts by default
  on macOS. The scroll-line bindings that use them will silently do
  nothing until you turn those off in System Settings → Keyboard →
  Keyboard Shortcuts → Mission Control (or accept that macOS wins). **This
  extension can't fix that from inside VS Code** — no keybindings
  contribution can out-race an OS-level hotkey.
- **Ctrl+Left / Ctrl+Right** are the same Mission Control/Spaces
  collision, but PCMode itself solves this one from outside the app: it
  remaps Ctrl+Left/Right to Option+Left/Right (word navigation) in its own
  event tap, ahead of Mission Control's own dispatch — the one PCMode
  keyboard remap that still applies in VS Code despite it otherwise being
  fully excluded (see the main repo's README). Only relevant if you're
  running this extension without PCMode (e.g. on someone else's Mac): in
  that case Ctrl+Left/Right will silently do nothing, same as Ctrl+Up/Down
  above, until Mission Control's shortcuts are turned off.
- **F11** (Toggle Full Screen) may be claimed by Mission Control's "Show
  Desktop" binding, or by media-key/Fn behavior on laptop keyboards.

One entry, plain **Ctrl+A → Select All**, is bound to
`editor.action.selectAll` as a best guess — Cmd+A already works natively
via Electron's own Edit-menu handling, so this repo hasn't been able to
confirm that command id resolves to anything in every context. If it's a
no-op for you, open the Keyboard Shortcuts editor (Cmd+K Cmd+S), search
"select all" in the command column to find the real id, and fix the entry
in `package.json` — or just delete it, since Cmd+A likely already works
without it.

## Why an extension instead of a `keybindings.json` you paste in

A personal `keybindings.json` works too, and is easier to tweak by hand.
This is packaged as an extension instead because it's easier to install,
update, and uninstall cleanly (no merge-by-hand into a file that might
already have your own customizations), and it travels with you across
machines via Settings Sync if you use that.

## License

MIT — see [LICENSE](LICENSE).
