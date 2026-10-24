using System.Runtime.InteropServices;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Native;

/// <summary>
/// Low-level mouse hook (WH_MOUSE_LL) — only button-down events. A click moves the caret or
/// makes a selection, so the keystroke buffer no longer mirrors the word at the caret and a
/// pending reconvert would delete the wrong text; the owner resets both. The macOS event tap
/// watches mouse clicks for the same reason. We never inject clicks, so no marker filtering.
/// </summary>
internal sealed class MouseHook : IDisposable
{
    // The delegate MUST be held in a field (same pitfall as KeyboardHook).
    private readonly LowLevelKeyboardProc _proc;
    private IntPtr _hook;

    /// <summary>Any mouse button pressed.</summary>
    public event Action? ButtonDown;

    public MouseHook() => _proc = HookCallback;

    public void Install()
    {
        _hook = SetWindowsHookExW(WH_MOUSE_LL, _proc, GetModuleHandleW(null), 0);
        if (_hook == IntPtr.Zero)
            throw new InvalidOperationException($"SetWindowsHookEx(mouse) failed (error {Marshal.GetLastWin32Error()})");
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == HC_ACTION)
        {
            int msg = (int)wParam;
            if (msg is WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_MBUTTONDOWN)
                ButtonDown?.Invoke();
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }
}
