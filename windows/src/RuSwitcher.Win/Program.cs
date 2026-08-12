using RuSwitcher.Win.Core;
using RuSwitcher.Win.Native;
using RuSwitcher.Win.Tray;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win;

// RuSwitcher for Windows — manual-trigger conversion, mirroring the macOS engine:
// LL hook → keystroke buffer → ToUnicodeEx map → SendInput retype → layout switch. Clipboard-free
// for typed words; a clipboard round-trip is used only for converting an existing selection.
// The trigger defaults to a double-tap of Ctrl (works on all keyboards incl. laptops, doesn't
// disturb typing — the Windows counterpart of the macOS Option double-tap), selectable in the tray.
internal static class Program
{
    [STAThread]  // required for WinForms clipboard / dialogs
    private static void Main()
    {
        string logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RuSwitcher");
        Directory.CreateDirectory(logDir);
        string logPath = Path.Combine(logDir, "debug.log");
        void Log(string line) => File.AppendAllText(logPath, $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}");

        // Only one process may own the global low-level keyboard hook. Multiple instances would
        // observe the same physical keystrokes and race to inject converted text.
        using var singleInstance = new Mutex(initiallyOwned: true, @"Local\RuSwitcher", out bool isFirstInstance);
        if (!isFirstInstance)
        {
            Log("startup skipped: another RuSwitcher instance is already running");
            return;
        }

        // Capture crashes to the log instead of dying silently (a tester can then send debug.log).
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        { try { Log("FATAL: " + (e.ExceptionObject as Exception)?.ToString()); } catch { /* ignore */ } };
        System.Windows.Forms.Application.ThreadException += (_, e) =>
        { try { Log("THREAD-EX: " + e.Exception); } catch { /* ignore */ } };

        var settings = Settings.Current;
        var buffer = new KeystrokeBuffer();
        bool enabled = true;
        List<TypedKey>? pendingAuto = null;   // word snapshot handed to the message loop for auto-convert

        // Auto-conversion checks the dictionary on the message loop; warm the COM spell-checker for the
        // actually-installed layout languages now, so the first auto-convert of the session isn't slow.
        if (settings.AutoConvert && Dict.Available)
        {
            try
            {
                foreach (var hkl in LayoutSwitcher.Installed())
                    Dict.IsValidWord("test", SmartConvert.LangTag(hkl));
            }
            catch { /* ignore */ }
        }

        using var tray = new TrayIcon();
        var detector = new TriggerDetector(settings.Trigger);

        // Hook thread: only post a message — the real (possibly slow, clipboard-touching)
        // conversion runs on the message loop so the LL hook callback stays fast.
        detector.Triggered += () => { if (enabled) tray.PostTrigger(); };

        // issue #14: a separate hotkey that only switches the layout (fast → safe in-callback).
        var switchDetector = new TriggerDetector(settings.SwitchTrigger);
        switchDetector.Triggered += () =>
        {
            if (enabled && settings.SwitchTriggerEnabled && LayoutSwitcher.Opposite() is { } opp)
                LayoutSwitcher.SwitchTo(opp);
        };

        tray.TriggerActivated += () =>
        {
            if (!enabled) return;
            // Trigger again with nothing typed since = reverse the last conversion (toggle);
            // else whole-line mode → convert the line; else convert the typed word; else the selection.
            bool acted;
            if (Converter.CanReconvert && buffer.IsEmpty) acted = Converter.Reconvert();
            else if (settings.ConvertWholeLine) { acted = Converter.ConvertLine(settings.SmartConversion); if (acted) buffer.Reset(); }
            else if (!buffer.IsEmpty) acted = Converter.ConvertLastWord(buffer);
            else acted = Converter.ConvertSelection(settings.SmartConversion);
            Log($"trigger: acted={acted}");
        };
        tray.AutoConvertActivated += () =>
        {
            // Deferred off the hook callback: the real Space has already landed, so TryConvertWord
            // deletes the word + that space and re-types the converted word + space (or keeps it).
            if (pendingAuto is { } w) { AutoConverter.TryConvertWord(w); pendingAuto = null; }
        };
        tray.EnabledChanged += on => { enabled = on; Log($"enabled = {on}"); };
        tray.TriggerChanged += kind => { detector.Kind = kind; Log($"trigger set: {kind}"); };  // Settings written by the tray
        tray.SettingsRequested += () =>
        {
            using var form = new UI.SettingsForm();
            form.TriggerChanged += kind => detector.Kind = kind;
            form.SwitchChanged += () => switchDetector.Kind = settings.SwitchTrigger;
            form.ShowDialog();   // modal; the message loop keeps pumping the hook + tray
        };
        tray.QuitRequested += () => Log("quit requested");
        tray.Show("RuSwitcher");

        // A hidden WinForms control forces a WindowsFormsSynchronizationContext onto this thread, so
        // the background update check can marshal its message box back here (dispatched by our loop).
        using var uiAnchor = new System.Windows.Forms.Control();
        _ = uiAnchor.Handle;   // force handle creation → installs the sync context
        var ui = SynchronizationContext.Current ?? new SynchronizationContext();
        tray.UpdateRequested += () => Updater.CheckNow(ui);

        using var hook = new KeyboardHook();
        hook.KeyDown += (vk, sc) =>
        {
            if (!enabled) return;

            detector.OnKeyDown(vk);
            switchDetector.OnKeyDown(vk);

            if (KeystrokeBuffer.IsWordBoundary(vk))
            {
                // As-you-type auto conversion (beta): on Space, arm a deferred check. We snapshot the
                // word and post to the message loop — the dictionary check + retype must NOT run inside
                // this LL-hook callback (COM/SendInput there risks the LowLevelHooksTimeout → unhook).
                // We do NOT swallow the space; the deferred handler deletes the word + delivered space.
                if (vk == KeystrokeBuffer.VK_SPACE && settings.AutoConvert && !buffer.IsEmpty)
                {
                    pendingAuto = new List<TypedKey>(buffer.CurrentWord);
                    tray.PostAutoConvert();
                }
                buffer.Reset();
                return;
            }

            if (KeystrokeBuffer.IsTypingKey(vk))
            {
                Converter.ClearReconvert();  // typing changed the word — the pending undo no longer applies
                // GetAsyncKeyState = real hardware state; GetKeyState would be stale on the hook thread.
                bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
                bool caps = (GetKeyState(VK_CAPITAL) & 0x0001) != 0;
                buffer.Append(new TypedKey(vk, sc, shift, caps));
            }
            // Modifiers and other keys: leave the buffer as-is.
        };
        hook.KeyUp += (vk, sc) =>
        {
            if (!enabled) return;
            detector.OnKeyUp(vk);
            switchDetector.OnKeyUp(vk);
        };
        hook.Install();

        // Per-app layout memory (issue): restores each app's last-used layout on focus. Off by default.
        using var appTracker = new AppLayoutTracker();
        appTracker.Install();

        Updater.CheckOnLaunch(ui);   // silent, throttled once-a-day, off the startup path

        Log($"RuSwitcher.Win started — hook + tray up, trigger={settings.Trigger}");

        // Message loop: required for both the LL hook callbacks and the tray window.
        while (GetMessageW(out MSG msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
    }
}
