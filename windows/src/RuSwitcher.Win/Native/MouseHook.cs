using System.Runtime.InteropServices;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Native;

/// <summary>Resets the typed-word buffer when the user clicks somewhere else. The macOS event tap
/// watches mouse-down for the same reason: without it a trigger can edit a field that never received
/// the buffered keystrokes.</summary>
internal sealed class MouseHook : IDisposable
{
    private readonly LowLevelMouseProc _proc;
    private IntPtr _hook;

    public event Action? Clicked;

    public MouseHook() => _proc = HookCallback;

    public void Install()
    {
        _hook = SetWindowsHookExMouseW(WH_MOUSE_LL, _proc, GetModuleHandleW(null), 0);
        if (_hook == IntPtr.Zero)
            throw new InvalidOperationException($"SetWindowsHookEx mouse failed (error {Marshal.GetLastWin32Error()})");
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == HC_ACTION && (int)wParam is WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_MBUTTONDOWN)
            Clicked?.Invoke();
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }
}
