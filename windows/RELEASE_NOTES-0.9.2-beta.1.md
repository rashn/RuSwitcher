# RuSwitcher 0.9.2 beta 1 for Windows

This local beta makes selection and whole-line correction reliable enough for daily testing while
keeping the already working last-word engine unchanged.

## What works now

- Convert selected text with the normal double-Ctrl trigger.
- Convert from the caret to the beginning of the current line when whole-line mode is enabled.
- Preserve the user's complete clipboard payload, including non-text formats.
- Retry temporarily busy clipboard operations and wait for applications that publish copied text
  asynchronously.
- Restore all persisted settings after restart. This fixes trigger, whole-line, smart conversion,
  sound, auto-conversion and per-app settings unexpectedly reverting to defaults.
- Native ARM64 single-file build and per-user installer.

## Verified locally

- ARM64 Windows 11.
- English US and Russian layouts.
- Standard Windows/WinForms text fields.
- Selection: `ghbdtn` → `привет`.
- Whole line: `ghbdtn` → `привет`.
- Clipboard restoration with Unicode text and a custom binary format.
- 38 automated tests.

## Still being hardened

- Modern Notepad session tabs, Office, Chromium/Electron editors and terminals need their own
  compatibility passes.
- Elevated/protected fields cannot accept synthetic input from a normal user process by Windows
  design; RuSwitcher now reports the failure but does not bypass that protection.
- The installer is currently unsigned and Windows may show a SmartScreen warning.
