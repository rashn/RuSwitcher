using System.Text;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Small, explicit compatibility gates for application classes whose editing model is
/// fundamentally different from a normal document control.</summary>
internal static class AppCompatibility
{
    private static readonly HashSet<string> TerminalProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "windowsterminal", "openconsole", "conhost", "cmd", "powershell", "pwsh",
        "wezterm", "alacritty", "hyper", "mintty",
    };

    private static readonly HashSet<string> KeyboardCopyProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome", "msedge", "chromium", "electron", "code", "discord", "slack", "spotify",
        "notion", "obsidian", "teams", "ms-teams",
    };

    public static bool IsTerminalForeground() =>
        ForegroundProcessName() is { } name && IsTerminalProcessName(name);

    public static bool UsesKeyboardCopyForeground() =>
        ForegroundProcessName() is { } name && UsesKeyboardCopyProcessName(name);

    internal static bool IsTerminalProcessName(string name) => TerminalProcesses.Contains(name);
    internal static bool UsesKeyboardCopyProcessName(string name) => KeyboardCopyProcesses.Contains(name);

    internal static string? ForegroundProcessName() => ProcessName(GetForegroundWindow());

    private static string? ProcessName(IntPtr hwnd)
    {
        GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == 0) return null;
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero) return null;
        try
        {
            var path = new StringBuilder(1024);
            uint size = (uint)path.Capacity;
            if (!QueryFullProcessImageNameW(process, 0, path, ref size)) return null;
            return System.IO.Path.GetFileNameWithoutExtension(path.ToString());
        }
        finally { CloseHandle(process); }
    }
}
