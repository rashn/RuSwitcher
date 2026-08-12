# RuSwitcher for Windows 0.10.0-beta.1

First compact native beta of the zero-dependency Windows port.

## Included

- double-Ctrl conversion of the last typed word, with repeat-to-undo;
- universal selected-text conversion, including multiple lines;
- exact clipboard restoration after selection conversion;
- current-line conversion from the tray;
- protected/password field detection;
- pause/resume, selectable layout pair and launch-at-sign-in in the tray;
- standalone ARM64 and x64 executables with no bundled runtime.

## Beta notes

- Binaries are unsigned until a Windows code-signing certificate is configured.
- No automatic updates are enabled in this beta.
- Diagnostics are written locally to `%LOCALAPPDATA%\RuSwitcher\native.log` only after a failed
  conversion attempt; no telemetry or network service is used.
