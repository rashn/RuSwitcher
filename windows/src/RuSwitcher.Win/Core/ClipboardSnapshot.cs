using System.Collections.Specialized;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>An eager, best-effort copy of every available Windows clipboard format. Eager copying
/// avoids delayed-rendering owners changing what gets restored after RuSwitcher requests a selection.</summary>
internal sealed class ClipboardSnapshot
{
    private readonly DataObject? _data;

    private ClipboardSnapshot(DataObject? data) => _data = data;

    public static ClipboardSnapshot Capture()
    {
        IDataObject? source = Retry(() => Clipboard.GetDataObject());
        if (source is null) return new ClipboardSnapshot(null);

        var copy = new DataObject();
        foreach (string format in source.GetFormats(autoConvert: false).Distinct())
        {
            try
            {
                object? value = source.GetData(format, autoConvert: false);
                object? clone = CloneValue(value);
                if (clone is not null) copy.SetData(format, autoConvert: false, clone);
            }
            catch { /* one exotic format must not lose the common formats */ }
        }
        return new ClipboardSnapshot(copy);
    }

    public bool Restore() => _data is null
        ? RetryAction(Clipboard.Clear)
        : RetryAction(() => Clipboard.SetDataObject(_data, copy: true));

    /// <summary>Clear the clipboard, send Ctrl+C and wait for the selection owner to publish text.</summary>
    public static bool TryCopySelection(out string text, out string diagnostic)
    {
        text = "";
        diagnostic = "";
        TextInjector.WaitForPhysicalModifiersReleased();
        if (!RetryAction(Clipboard.Clear))
        {
            diagnostic = "clipboard is busy";
            return false;
        }

        uint clearedAt = GetClipboardSequenceNumber();

        // Standard Win32/WinForms/WPF/Office controls support WM_COPY directly. It avoids racing
        // the user's trigger Ctrl key and is the most deterministic path when a focused HWND exists.
        SendCopyToFocusedControl();
        if (WaitForCopiedText(clearedAt, Environment.TickCount64 + 180, out text)) return true;

        // Chromium/Electron and custom editors may ignore WM_COPY, so retain real Ctrl+C fallback.
        if (!RetryAction(Clipboard.Clear))
        {
            diagnostic = "clipboard became busy before Ctrl+C fallback";
            return false;
        }
        clearedAt = GetClipboardSequenceNumber();
        if (!TextInjector.SendCtrl(VK_C))
        {
            diagnostic = TextInjector.LastDiagnostic;
            return false;
        }

        if (WaitForCopiedText(clearedAt, Environment.TickCount64 + 800, out text)) return true;

        diagnostic = "selection did not publish text to the clipboard";
        return false;
    }

    private static void SendCopyToFocusedControl()
    {
        IntPtr foreground = GetForegroundWindow();
        uint thread = GetWindowThreadProcessId(foreground, out _);
        var info = new GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>() };
        IntPtr target = GetGUIThreadInfo(thread, ref info) && info.hwndFocus != IntPtr.Zero
            ? info.hwndFocus : foreground;
        if (target != IntPtr.Zero)
            SendMessageTimeoutW(target, WM_COPY, IntPtr.Zero, IntPtr.Zero,
                SMTO_ABORTIFHUNG, 150, out _);
    }

    private static bool WaitForCopiedText(uint clearedAt, long deadline, out string text)
    {
        text = "";
        while (Environment.TickCount64 < deadline)
        {
            if (GetClipboardSequenceNumber() != clearedAt)
            {
                string? copied = Retry(() => Clipboard.ContainsText(TextDataFormat.UnicodeText)
                    ? Clipboard.GetText(TextDataFormat.UnicodeText) : null, attempts: 2);
                if (!string.IsNullOrEmpty(copied))
                {
                    text = copied;
                    return true;
                }
            }
            Thread.Sleep(15);
        }
        return false;
    }

    private static object? CloneValue(object? value) => value switch
    {
        null => null,
        string s => s,
        string[] a => a.ToArray(),
        StringCollection c => CloneStrings(c),
        Bitmap b => new Bitmap(b),
        Image i => new Bitmap(i),
        MemoryStream s => new MemoryStream(s.ToArray(), writable: false),
        Stream s => CloneStream(s),
        byte[] b => b.ToArray(),
        _ => value,
    };

    private static StringCollection CloneStrings(StringCollection source)
    {
        var result = new StringCollection();
        result.AddRange(source.Cast<string>().ToArray());
        return result;
    }

    private static MemoryStream? CloneStream(Stream source)
    {
        try
        {
            long old = source.CanSeek ? source.Position : 0;
            if (source.CanSeek) source.Position = 0;
            var copy = new MemoryStream();
            source.CopyTo(copy);
            copy.Position = 0;
            if (source.CanSeek) source.Position = old;
            return copy;
        }
        catch { return null; }
    }

    private static T? Retry<T>(Func<T?> action, int attempts = 8)
    {
        for (int i = 0; i < attempts; i++)
        {
            try { return action(); }
            catch (ExternalException) { Thread.Sleep(15 + i * 10); }
        }
        return default;
    }

    private static bool RetryAction(Action action, int attempts = 8)
    {
        for (int i = 0; i < attempts; i++)
        {
            try { action(); return true; }
            catch (ExternalException) { Thread.Sleep(15 + i * 10); }
        }
        return false;
    }
}
