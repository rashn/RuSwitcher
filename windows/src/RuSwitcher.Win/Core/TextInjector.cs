using System.Runtime.InteropServices;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Deletes the typed word and reinserts the converted text via SendInput +
/// KEYEVENTF_UNICODE — the clipboard-free retype engine, the Windows counterpart of the
/// macOS <c>TextConverter</c> buffer engine. Our events carry <see cref="InjectedMarker"/>
/// so the hook ignores them.
/// </summary>
internal static class TextInjector
{
    public static string LastDiagnostic { get; private set; } = "";

    public static bool Replace(int backspaces, string text)
    {
        var inputs = new List<INPUT>(backspaces * 2 + text.Length * 2);

        for (int i = 0; i < backspaces; i++)
        {
            inputs.Add(Key(VK_BACK, '\0', dwFlags: 0));
            inputs.Add(Key(VK_BACK, '\0', dwFlags: KEYEVENTF_KEYUP));
        }
        foreach (char c in text)
        {
            inputs.Add(Key(0, c, dwFlags: KEYEVENTF_UNICODE));
            inputs.Add(Key(0, c, dwFlags: KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
        }

        var arr = inputs.ToArray();
        return Send(arr);
    }

    /// <summary>Send Ctrl+<paramref name="vk"/> (e.g. Ctrl+C / Ctrl+V).</summary>
    public static bool SendCtrl(ushort vk) => SendChord(VK_CONTROL, vk);

    /// <summary>Send Shift+<paramref name="vk"/> (e.g. Shift+Home to select to line start).</summary>
    public static bool SendShift(ushort vk) => SendChord((ushort)VK_SHIFT, vk);

    /// <summary>Send a single plain key press (e.g. End to collapse a selection).</summary>
    public static bool SendKey(ushort vk)
    {
        var inputs = new[] { Key(vk, '\0', dwFlags: 0), Key(vk, '\0', dwFlags: KEYEVENTF_KEYUP) };
        return Send(inputs);
    }

    // modVk + vk as one chord. Carries the injected marker so our own hook ignores it.
    private static bool SendChord(ushort modVk, ushort vk)
    {
        var inputs = new[]
        {
            Key(modVk, '\0', dwFlags: 0),
            Key(vk, '\0', dwFlags: 0),
            Key(vk, '\0', dwFlags: KEYEVENTF_KEYUP),
            Key(modVk, '\0', dwFlags: KEYEVENTF_KEYUP),
        };
        return Send(inputs);
    }

    /// <summary>True only when Windows accepted every requested event. SendInput may return a
    /// partial count (or zero) without throwing; treating that as success corrupts the user's text.</summary>
    private static bool Send(INPUT[] inputs)
    {
        if (inputs.Length == 0) { LastDiagnostic = ""; return true; }
        int inputSize = Marshal.SizeOf<INPUT>();
        uint sent = SendInput((uint)inputs.Length, inputs, inputSize);
        if (sent == (uint)inputs.Length) { LastDiagnostic = ""; return true; }
        LastDiagnostic = $"SendInput sent {sent}/{inputs.Length}, cbSize={inputSize}, error={Marshal.GetLastWin32Error()}";
        return false;
    }

    private static INPUT Key(ushort vk, char scanChar, uint dwFlags) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = vk,
                wScan = scanChar,
                dwFlags = dwFlags,
                time = 0,
                dwExtraInfo = InjectedMarker,
            }
        }
    };
}
