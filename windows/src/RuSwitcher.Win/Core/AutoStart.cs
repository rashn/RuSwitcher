using Microsoft.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Launch-at-login via the per-user Run registry key — the Windows counterpart of the
/// macOS login item. Fully defensive (registry access can fail under policy).</summary>
internal static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "RuSwitcher";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is not null;
        }
        catch { return false; }
    }

    public static void SetEnabled(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true)
                            ?? Registry.CurrentUser.CreateSubKey(RunKey);
            if (key is null) return;
            if (on)
            {
                string? exe = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exe)) key.SetValue(ValueName, $"\"{exe}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch { /* policy / access — ignore */ }
    }

    /// <summary>Keep an existing launch-at-login entry pointed at the currently running build.
    /// This matters after an installer upgrade or when replacing a portable beta.</summary>
    public static void RefreshIfEnabled()
    {
        if (IsEnabled()) SetEnabled(true);
    }
}
