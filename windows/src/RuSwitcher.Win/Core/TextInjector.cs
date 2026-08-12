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
        uint flags = ExtendedFlag(vk);
        VirtualKey(vk, flags);
        VirtualKey(vk, flags | KEYEVENTF_KEYUP);
        LastDiagnostic = "";
        return true;
    }

    /// <summary>Wait until the physical trigger chord is fully released. Injecting another chord
    /// while Ctrl/Shift/Alt/Win is still down can turn Shift+Home into Ctrl+Shift+Home or make a
    /// fallback Ctrl+C indistinguishable from the user's trigger.</summary>
    public static void WaitForPhysicalModifiersReleased(int timeoutMs = 300)
    {
        long deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            bool down = (GetAsyncKeyState(VK_CONTROL_STATE) & 0x8000) != 0
                     || (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0
                     || (GetAsyncKeyState(VK_MENU) & 0x8000) != 0
                     || (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0
                     || (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
            if (!down) break;
            Thread.Sleep(5);
        }
        Thread.Sleep(20); // let the foreground application consume the final key-up
    }

    // modVk + vk as one chord. Carries the injected marker so our own hook ignores it.
    private static bool SendChord(ushort modVk, ushort vk)
    {
        uint flags = ExtendedFlag(vk);
        VirtualKey(modVk, 0);
        VirtualKey(vk, flags);
        VirtualKey(vk, flags | KEYEVENTF_KEYUP);
        VirtualKey(modVk, KEYEVENTF_KEYUP);
        LastDiagnostic = "";
        return true;
    }

    private static void VirtualKey(ushort vk, uint flags) =>
        keybd_event((byte)vk, 0, flags, (UIntPtr)InjectedMarker);

    private static uint ExtendedFlag(ushort vk) => vk is
        0x21 or 0x22 or 0x23 or 0x24 or // PageUp, PageDown, End, Home
        0x25 or 0x26 or 0x27 or 0x28 or // arrows
        0x2D or 0x2E                    // Insert, Delete
            ? KEYEVENTF_EXTENDEDKEY : 0;

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
