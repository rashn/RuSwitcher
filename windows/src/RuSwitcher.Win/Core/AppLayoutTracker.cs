using System.Text;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Per-app keyboard-layout memory — the Windows counterpart of the macOS per-app layout feature.
/// Watches foreground-window changes (SetWinEventHook / EVENT_SYSTEM_FOREGROUND): when an app loses
/// focus its current layout is remembered against its process name, and when an app regains focus its
/// remembered layout is restored. Off unless <see cref="Settings.PerAppLayout"/>. Fully defensive.
/// </summary>
internal sealed class AppLayoutTracker : IDisposable
{
    // The callback delegate must be held in a field (else it's collected and the native call crashes).
    private readonly WinEventProc _proc;
    private IntPtr _hook;
    private string? _lastApp;   // process name of the app we last saw focused
    private uint _lastTid;      // its GUI thread id — sampled so we can read ITS layout when it loses focus

    public AppLayoutTracker() => _proc = OnForeground;

    public event Action? ForegroundChanged;

    public void Install()
    {
        // SKIPOWNPROCESS: never react to our own tray/settings windows getting focus.
        _hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero,
            _proc, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }

    private void OnForeground(IntPtr hHook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time)
    {
        try
        {
            if (hwnd == IntPtr.Zero) return;
            ForegroundChanged?.Invoke();
            if (!Settings.Current.PerAppLayout) return;

            // The event fires AFTER the foreground already switched, so GetForegroundWindow() is the
            // NEW app. To remember the OUTGOING app correctly, read the layout of ITS gui thread — a
            // thread keeps its active layout after losing focus, incl. any change made while focused.
            if (_lastApp is { } prev && _lastTid != 0)
            {
                long hkl = GetKeyboardLayout(_lastTid).ToInt64() & 0xFFFFFFFF;
                if (hkl != 0 &&
                    (!Settings.Current.AppLayouts.TryGetValue(prev, out long old) || old != hkl))
                {
                    Settings.Current.AppLayouts[prev] = hkl;   // dirty-check: only write on real change
                    Settings.Current.Save();
                }
            }

            uint tid = GetWindowThreadProcessId(hwnd, out _);
            string? app = ProcessName(hwnd);
            _lastApp = app;
            _lastTid = tid;
            if (app == null) return;

            // Restore the layout remembered for the app that just gained focus.
            if (Settings.Current.AppLayouts.TryGetValue(app, out long want) &&
                InstalledHkl(want) is { } target && target != GetKeyboardLayout(tid))
            {
                PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, target);
            }
        }
        catch { /* never let a shell event crash us */ }
    }

    /// <summary>Lower-cased executable base name (no ".exe") of the process owning a window.</summary>
    private static string? ProcessName(IntPtr hwnd)
    {
        GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == 0) return null;
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            uint cap = (uint)sb.Capacity;
            if (!QueryFullProcessImageNameW(h, 0, sb, ref cap)) return null;
            string name = System.IO.Path.GetFileNameWithoutExtension(sb.ToString());
            return string.IsNullOrEmpty(name) ? null : name.ToLowerInvariant();
        }
        finally { CloseHandle(h); }
    }

    /// <summary>Find an installed HKL matching a stored value: exact (variant-preserving) first, then
    /// fall back to the same primary language if that exact layout is no longer installed.</summary>
    private static IntPtr? InstalledHkl(long stored)
    {
        var installed = LayoutSwitcher.Installed();
        foreach (var hkl in installed)
            if ((hkl.ToInt64() & 0xFFFFFFFF) == stored) return hkl;
        long primary = stored & 0x3FF;
        foreach (var hkl in installed)
            if ((hkl.ToInt64() & 0x3FF) == primary) return hkl;
        return null;
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) { UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
    }
}
