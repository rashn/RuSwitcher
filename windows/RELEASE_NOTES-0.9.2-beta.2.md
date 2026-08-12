# RuSwitcher 0.9.2 beta 2 for Windows

This local compatibility beta extends the reliable selection work from beta 1 to the applications
that use non-standard Windows editing models.

## What works now

- Convert selected text in modern Notepad, Google Chrome and Microsoft Edge with double Ctrl.
- Convert a complete command line in Windows Terminal without sending Ctrl+C to the terminal.
- Preserve Unicode text and custom binary clipboard formats after browser selection conversion.
- Use native copy messages for standard document controls and a concrete keyboard-copy fallback for
  Chromium/Electron editors.
- Keep a full typed-line buffer for terminal conversion, including spaces and Backspace edits.
- Report clipboard sequence, foreground-window and format diagnostics when an editor refuses copy.

## Verified locally

- Native ARM64 Windows 11 build.
- English US and Russian layouts.
- Modern Notepad selection: `ghbdtn` → `привет`.
- Chrome and Edge selection: `ghbdtn` → `привет`.
- Windows Terminal whole line: `hello ghbdtn` → `hello привет`.
- Clipboard restoration with Unicode text and a custom binary format.
- 52 automated tests, including terminal/application compatibility routing.

## Still being hardened

- Office and standalone Electron applications need dedicated installed-app passes.
- Elevated/protected fields cannot accept synthetic input from a normal user process by Windows
  design; RuSwitcher reports the failure and does not bypass that boundary.
- The installer is unsigned, so Windows may show a SmartScreen warning.
