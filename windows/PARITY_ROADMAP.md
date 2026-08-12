# Windows parity roadmap

The macOS application is the behavioural reference. Windows releases should copy its user-visible
behaviour in small, testable slices; a feature is not considered parity merely because a Win32
counterpart exists.

## macOS capability map

| Area | macOS reference behaviour | Windows status before 0.9.1 |
|---|---|---|
| Manual correction | Keycode-based last-word conversion, literal trailing punctuation, toggle/undo | Implemented, but non-ASCII `ToUnicodeEx` output and `SendInput` ABI bugs broke real use |
| Editing safety | Tracks Backspace and caret movement; invalidates buffered text after mouse/focus changes | Missing |
| Selection and line | Selection conversion, smart per-word mode, whole-line mode, app-specific fallbacks | Implemented in basic form; compatibility matrix not verified |
| Layout pair | Explicit choice of any two installed layouts; dynamic mapping and RTL-safe conversion | Windows always chooses the first layout that is not current |
| Conversion trigger | Left/right modifiers, single/double tap, Caps Lock, modifier combos | Double Ctrl, double Shift, or Pause only |
| Switch-only hotkey | Independent modifier/combo trigger with side and double-tap options | Basic double Ctrl/Shift/Pause trigger |
| Auto-conversion | Dictionary confidence, short-word lists, punctuation ambiguity handling, secure-field and denied-app gates, always/never lists, learn-from-undo | Basic dictionary path and word lists; safety policy is incomplete |
| Application compatibility | Clipboard-free primary path plus targeted fallbacks for unusual fields, terminals, Spotlight and remote sessions | Unicode injection plus a generic clipboard selection fallback |
| Layout UX | Menu layout picker, current flag/badge, optional caret flag, sound on first typed character after a switch | Current layout text in tray menu and immediate system sound |
| Session behaviour | Per-app layout memory, launch at login, remote-desktop mode | Per-app memory and launch-at-login exist; remote mode missing |
| Product UX | Localized tabbed settings, About/support/share, beta channel, What's New, debug-log controls | Small EN/RU settings dialog and basic update link |
| Distribution | Signed/notarized app, verified update, stable/beta feeds | Self-contained exe and unsigned Inno Setup script |

## Release slices

### 0.9.1 beta — reliable core

- Native ARM64 and x64 builds.
- Last-word EN/RU conversion and repeated-trigger undo verified end to end.
- Correct UTF-16 marshalling and Win32 `INPUT` ABI.
- Backspace-aware buffer; caret, shortcut, click and focus invalidation.
- One global hook owner, actionable diagnostics, real app/tray icon and local installer.

### 0.9.2 beta — selection and compatibility

- Verify selection and whole-line conversion in Notepad, Office, browsers, Electron editors and terminals.
- Preserve all clipboard formats, not only text.
- Add safe fallbacks per application class and visible failure feedback.
- Regression scenarios for punctuation, mixed text and protected/elevated windows.

### 0.9.3 beta — layout control

- Explicit two-layout selection in Settings.
- Installed-layout picker in the tray with current-layout checkmark.
- Stable identity for layout variants and stronger per-app layout memory.
- Layout-aware tray badge and optional caret indicator.

### 0.10 beta — safe automatic correction

- Port the full macOS policy: denied applications, password/secure-field protection, short-word lists,
  punctuation ambiguity, Caps Lock/code/URL gates and Hebrew conservative direction.
- Complete exception editors and learn-from-undo UX.
- Auto-conversion stays off by default until false-positive testing passes.

### 0.11 beta — hotkeys and daily UX

- Left/right modifier choice, single/double tap, Caps Lock and modifier combinations.
- Equivalent flexibility for the independent switch-only hotkey.
- Sound timing parity, onboarding, richer settings and diagnostics controls.

### 0.12 release candidate — product and distribution

- Wider localization, About/support/share and What's New.
- Stable/beta update channels with checksum and signature verification.
- Signed installers, upgrade/uninstall/autostart tests and x64/ARM64 release automation.

Remote-desktop parity is a separate later slice because Windows RDP/remote-input behaviour is not a
direct translation of the macOS Screen Sharing event-tap design.
