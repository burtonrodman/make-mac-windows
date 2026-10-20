# Changelog

## 0.1.2

Fixed: plain Home/End (and Shift+Home/Shift+End) did nothing — only the
Ctrl+Home/Ctrl+End document-navigation pair was bound, so line-relative
Home/End fell through to whatever VS Code did natively, which for the chat
sidebar's webview-hosted input was nothing at all. Added `home`/`end`
bound to `cursorHome`/`cursorEnd`, and `shift+home`/`shift+end` to their
`*Select` counterparts, all under `textInputFocus` like the existing pair.

## 0.1.1

Fixed: plain Ctrl+V (paste in the regular editor, `editor.action.clipboardPasteAction`)
was missing entirely — 0.1.0 only bound Ctrl+V inside the integrated
terminal (`terminalFocus`), so pasting outside the terminal silently did
nothing. Found via VS Code's "Developer: Toggle Keyboard Shortcuts
Troubleshooting" log, which showed the terminal-scoped rule's `when`
clause correctly evaluating false with no other rule to fall back to.

## 0.1.0

Initial release — ~100 keybindings covering general commands, basic
editing, navigation, search and replace, multi-cursor and selection, rich
language editing, editor/file management, display, and the integrated
terminal, sourced from Microsoft's official Windows and macOS keyboard
shortcut references (https://aka.ms/vscodekeybindings).
