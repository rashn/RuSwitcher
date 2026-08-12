# Compact native Windows target

This is the final-product target. The current C# application is the behavioural beta/oracle while
features are migrated and verified against the same end-to-end scenario matrix.

Hard constraints:

- fully standalone `RuSwitcher.exe`; no .NET, Electron or bundled runtime;
- x64 and ARM64;
- release executable budget: **5 MiB maximum**, preferred 1–2 MiB;
- Windows system DLLs only (`user32`, `ole32`, `uiautomationcore`, etc.);
- application names never control conversion behaviour;
- protected/password fields are capability-detected before copy, deletion or injection.

Build on a Visual Studio Windows runner:

```powershell
cmake -S windows/native -B build/native -A x64
cmake --build build/native --config Release
pwsh scripts/check_windows_binary_size.ps1 build/native/Release/RuSwitcher.exe
```

The native target must not replace the installed beta until it passes word, selection, whole-line,
clipboard restoration, caret/mouse invalidation, multiline and protected-field scenarios.

## Migration status

Verified locally on Windows ARM64 with real input events:

- standalone ARM64 and x64 release builds;
- double-Ctrl conversion of the buffered last word (`ghbdtn` to `привет`);
- repeated-trigger undo (`привет` back to `ghbdtn`);
- standard password fields are detected and left unchanged;
- Backspace is mirrored in the typed-word buffer;
- caret movement, mouse clicks, shortcuts and focus/window changes invalidate stale text;
- the executable imports Windows system DLLs only.

Current release sizes are 110.5 KiB (ARM64) and 123.5 KiB (x64). The next acceptance slice is
universal selection and whole-line conversion with full clipboard restoration and multiline tests.
