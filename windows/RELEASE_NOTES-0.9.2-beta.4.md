# RuSwitcher 0.9.2 beta 4 for Windows

This beta replaces application-specific compatibility lists with universal, state-based routing.

- Typed words always convert from RuSwitcher's keyboard buffer, without clipboard access.
- Whole lines typed during the current focus session convert from the line buffer in every editor.
- Pre-existing selections probe capabilities in a universal order: real keyboard copy first, then
  native focused-control copy if the keyboard command produced no clipboard data.
- Application names are retained only in diagnostics and never affect conversion behaviour.
- Notepad, browsers, Electron editors and terminals are regression scenarios rather than branches
  in the production engine.
