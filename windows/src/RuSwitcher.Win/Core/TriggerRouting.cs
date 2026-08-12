using System.Text;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

internal enum TriggerAction
{
    Reconvert,
    BufferedWord,
    BufferedLine,
    SelectedText,
    SystemLine,
}

/// <summary>Selects a conversion mechanism only from state RuSwitcher actually knows. Application
/// names are deliberately not part of this decision: an editor upgrade or a new Electron shell
/// must not require another compatibility entry.</summary>
internal static class TriggerRouting
{
    public static TriggerAction Decide(bool wholeLine, bool canReconvert, int wordKeys, int lineKeys)
    {
        if (canReconvert && wordKeys == 0 && lineKeys == 0) return TriggerAction.Reconvert;
        if (wholeLine && lineKeys > 0) return TriggerAction.BufferedLine;
        if (!wholeLine && wordKeys > 0) return TriggerAction.BufferedWord;
        return wholeLine ? TriggerAction.SystemLine : TriggerAction.SelectedText;
    }

    /// <summary>Process name is diagnostic context only and never controls routing.</summary>
    public static string ForegroundProcessName()
    {
        IntPtr hwnd = GetForegroundWindow();
        GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == 0) return "unknown";
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero) return "unknown";
        try
        {
            var path = new StringBuilder(1024);
            uint size = (uint)path.Capacity;
            if (!QueryFullProcessImageNameW(process, 0, path, ref size)) return "unknown";
            return Path.GetFileNameWithoutExtension(path.ToString());
        }
        finally { CloseHandle(process); }
    }
}
