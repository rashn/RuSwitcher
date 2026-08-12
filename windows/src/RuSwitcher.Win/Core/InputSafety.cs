using System.Runtime.InteropServices;
using System.Windows.Automation;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Capability-based safety boundary for password/protected editors. It asks Windows for
/// the focused control's password property and never reads the control's value.</summary>
internal static class InputSafety
{
    public static bool IsProtectedForeground()
    {
        IntPtr foreground = GetForegroundWindow();
        uint thread = GetWindowThreadProcessId(foreground, out _);
        var info = new GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>() };
        IntPtr focusedHwnd = GetGUIThreadInfo(thread, ref info) && info.hwndFocus != IntPtr.Zero
            ? info.hwndFocus : foreground;

        if (focusedHwnd != IntPtr.Zero && IsPasswordStyle(GetWindowLongW(focusedHwnd, GWL_STYLE)))
            return true;

        try
        {
            AutomationElement? focused = AutomationElement.FocusedElement;
            object value = focused?.GetCurrentPropertyValue(
                AutomationElement.IsPasswordProperty, ignoreDefaultValue: true)
                ?? AutomationElement.NotSupported;
            return value is bool isPassword && isPassword;
        }
        catch (ElementNotAvailableException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (COMException) { return false; }
    }

    internal static bool IsPasswordStyle(int style) => (style & ES_PASSWORD) != 0;
}
