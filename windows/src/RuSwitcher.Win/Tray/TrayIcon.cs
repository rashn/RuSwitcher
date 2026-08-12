using RuSwitcher.Win.Core;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Tray;

/// <summary>
/// Menu-bar presence — the Windows counterpart of the macOS NSStatusItem. A hidden message
/// window receives tray callbacks; right-click shows a menu: Enable toggle, a Trigger submenu,
/// a whole-line toggle, «Settings…», and Quit. Menu state is read live from Settings.Current
/// so it stays in sync with the settings window.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint ID_ENABLE = 1;
    private const uint ID_QUIT = 2;
    private const uint ID_TRIG_CTRL = 10;
    private const uint ID_TRIG_SHIFT = 11;
    private const uint ID_TRIG_PAUSE = 12;
    private const uint ID_WHOLELINE = 13;
    private const uint ID_SETTINGS = 14;
    private const uint ID_AUTO = 15;
    private const uint ID_UPDATE = 16;

    private readonly WndProc _wndProc;
    private IntPtr _hwnd;
    private NOTIFYICONDATA _nid;
    private System.Drawing.Icon? _appIcon;
    private bool _enabled = true;

    public event Action<bool>? EnabledChanged;
    public event Action<TriggerKind>? TriggerChanged;
    public event Action? SettingsRequested;
    public event Action? UpdateRequested;
    public event Action? QuitRequested;
    /// <summary>Fired on the message-loop thread when a trigger was posted from the hook.</summary>
    public event Action? TriggerActivated;
    /// <summary>Fired on the message-loop thread when an as-you-type auto-convert was posted from the hook.</summary>
    public event Action? AutoConvertActivated;

    public TrayIcon() => _wndProc = WindowProc;

    /// <summary>Called from the LL hook callback: posts a message so the actual (possibly slow,
    /// clipboard-touching) conversion runs on the message loop, NOT inside the hook callback —
    /// keeping the callback fast so Windows never drops the low-level hook (300ms timeout).</summary>
    public void PostTrigger()
    {
        if (_hwnd != IntPtr.Zero) PostMessageW(_hwnd, WM_APP, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>Called from the LL hook callback on a word boundary when auto-convert is armed: posts a
    /// message so the dictionary check + retype run on the message loop, never inside the callback.</summary>
    public void PostAutoConvert()
    {
        if (_hwnd != IntPtr.Zero) PostMessageW(_hwnd, WM_AUTOCONVERT, IntPtr.Zero, IntPtr.Zero);
    }

    public void Show(string tooltip)
    {
        IntPtr hInstance = GetModuleHandleW(null);
        var wc = new WNDCLASS
        {
            lpfnWndProc = _wndProc,
            hInstance = hInstance,
            lpszClassName = "RuSwitcherTrayWindow",
        };
        RegisterClassW(ref wc);

        _hwnd = CreateWindowExW(0, "RuSwitcherTrayWindow", "RuSwitcher",
            0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);

        try
        {
            string? exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe)) _appIcon = System.Drawing.Icon.ExtractAssociatedIcon(exe);
        }
        catch { /* use the system fallback below */ }

        _nid = new NOTIFYICONDATA
        {
            cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon = _appIcon?.Handle ?? LoadIconW(IntPtr.Zero, IDI_APPLICATION),
            szTip = tooltip,
        };
        Shell_NotifyIconW(NIM_ADD, ref _nid);
    }

    internal static string TriggerName(TriggerKind t) => t switch
    {
        TriggerKind.CtrlDoubleTap => L10n.T("trigger.ctrl"),
        TriggerKind.ShiftDoubleTap => L10n.T("trigger.shift"),
        TriggerKind.PauseBreak => L10n.T("trigger.pause"),
        _ => "?",
    };

    /// <summary>issue #7 (indicator): human-readable name of a layout from its HKL primary LANGID.</summary>
    private static string LayoutName(IntPtr hkl) => ((int)hkl.ToInt64() & 0x3FF) switch
    {
        0x19 => "Русский",
        0x09 => "English",
        0x22 => "Українська",
        0x23 => "Беларуская",
        0x02 => "Български",
        0x0D => "עברית",
        0x08 => "Ελληνικά",
        0x2B => "Հայերեն",
        0x37 => "ქართული",
        _ => "Layout",
    };

    private IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_TRAYICON when ((uint)(lParam.ToInt64() & 0xFFFF)) is WM_RBUTTONUP or WM_LBUTTONUP:
                ShowMenu();
                return IntPtr.Zero;

            case WM_APP:
                TriggerActivated?.Invoke();
                return IntPtr.Zero;

            case WM_AUTOCONVERT:
                AutoConvertActivated?.Invoke();
                return IntPtr.Zero;

            case WM_COMMAND:
                uint cmd = (uint)(wParam.ToInt64() & 0xFFFF);
                switch (cmd)
                {
                    case ID_ENABLE: _enabled = !_enabled; EnabledChanged?.Invoke(_enabled); break;
                    case ID_QUIT: QuitRequested?.Invoke(); PostQuitMessage(0); break;
                    case ID_SETTINGS: SettingsRequested?.Invoke(); break;
                    case ID_UPDATE: UpdateRequested?.Invoke(); break;
                    case ID_TRIG_CTRL: SetTrigger(TriggerKind.CtrlDoubleTap); break;
                    case ID_TRIG_SHIFT: SetTrigger(TriggerKind.ShiftDoubleTap); break;
                    case ID_TRIG_PAUSE: SetTrigger(TriggerKind.PauseBreak); break;
                    case ID_WHOLELINE:
                        Settings.Current.ConvertWholeLine = !Settings.Current.ConvertWholeLine;
                        Settings.Current.Save();
                        break;
                    case ID_AUTO:
                        Settings.Current.AutoConvert = !Settings.Current.AutoConvert;
                        Settings.Current.Save();
                        break;
                }
                return IntPtr.Zero;

            case WM_DESTROY:
                PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void SetTrigger(TriggerKind t)
    {
        if (t == Settings.Current.Trigger) return;
        Settings.Current.Trigger = t;
        Settings.Current.Save();
        TriggerChanged?.Invoke(t);
    }

    private void ShowMenu()
    {
        var s = Settings.Current;
        IntPtr menu = CreatePopupMenu();

        // Layout indicator (disabled header, issue #7): shows the current keyboard layout.
        AppendMenuW(menu, MF_STRING | MF_DISABLED | MF_GRAYED, 0, $"⌨  {LayoutName(LayoutSwitcher.Current())}");
        AppendMenuW(menu, MF_SEPARATOR, 0, null);

        AppendMenuW(menu, MF_STRING | (_enabled ? MF_CHECKED : MF_UNCHECKED), ID_ENABLE, L10n.T("tray.enable"));

        IntPtr sub = CreatePopupMenu();
        AppendMenuW(sub, MF_STRING | Chk(s.Trigger == TriggerKind.CtrlDoubleTap), ID_TRIG_CTRL, TriggerName(TriggerKind.CtrlDoubleTap));
        AppendMenuW(sub, MF_STRING | Chk(s.Trigger == TriggerKind.ShiftDoubleTap), ID_TRIG_SHIFT, TriggerName(TriggerKind.ShiftDoubleTap));
        AppendMenuW(sub, MF_STRING | Chk(s.Trigger == TriggerKind.PauseBreak), ID_TRIG_PAUSE, TriggerName(TriggerKind.PauseBreak));
        AppendSubMenuW(menu, MF_STRING | MF_POPUP, sub, L10n.T("tray.trigger", TriggerName(s.Trigger)));

        AppendMenuW(menu, MF_STRING | Chk(s.ConvertWholeLine), ID_WHOLELINE, L10n.T("tray.wholeline"));
        AppendMenuW(menu, MF_STRING | Chk(s.AutoConvert), ID_AUTO, L10n.T("tray.auto"));
        AppendMenuW(menu, MF_STRING, ID_SETTINGS, L10n.T("tray.settings"));
        AppendMenuW(menu, MF_STRING, ID_UPDATE, L10n.T("tray.update"));

        AppendMenuW(menu, MF_SEPARATOR, 0, null);
        AppendMenuW(menu, MF_STRING, ID_QUIT, L10n.T("tray.quit"));

        GetCursorPos(out POINT pt);
        SetForegroundWindow(_hwnd); // so the menu dismisses correctly on outside click
        TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.X, pt.Y, 0, _hwnd, IntPtr.Zero);
        DestroyMenu(menu);
    }

    private static uint Chk(bool on) => on ? MF_CHECKED : MF_UNCHECKED;

    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero)
        {
            Shell_NotifyIconW(NIM_DELETE, ref _nid);
            DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
        _appIcon?.Dispose();
        _appIcon = null;
    }
}
