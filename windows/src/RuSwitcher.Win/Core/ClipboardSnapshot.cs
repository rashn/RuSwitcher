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
        IntPtr foregroundAtStart = GetForegroundWindow();
        if (!ClearForCopy())
        {
            diagnostic = "clipboard is busy";
            return false;
        }

        uint clearedAt = GetClipboardSequenceNumber();

        // First ask every editor through the same real keyboard command. This covers custom,
        // Chromium/Electron and terminal-like controls without knowing their executable names.
        IntPtr foregroundAtFallback = GetForegroundWindow();
        if (!TextInjector.SendCtrl(VK_C))
        {
            diagnostic = TextInjector.LastDiagnostic;
            return false;
        }

        if (WaitForCopiedText(clearedAt, Environment.TickCount64 + 650, out text)) return true;

        // Some native document controls only implement WM_COPY reliably. Probe that capability
        // only after the keyboard path has demonstrably produced nothing. The order matters:
        // sending an unsupported WM_COPY before Ctrl+C can suppress asynchronous browser copies.
        if (!ClearForCopy())
        {
            diagnostic = "clipboard became busy before native copy fallback";
            return false;
        }
        clearedAt = GetClipboardSequenceNumber();
        SendCopyToFocusedControl();
        if (WaitForCopiedText(clearedAt, Environment.TickCount64 + 300, out text)) return true;

        uint finalSequence = GetClipboardSequenceNumber();
        string formats;
        try { formats = string.Join(",", Clipboard.GetDataObject()?.GetFormats(false) ?? Array.Empty<string>()); }
        catch { formats = "busy"; }
        diagnostic = $"selection did not publish text to the clipboard " +
            $"(seq {clearedAt}->{finalSequence}, hwnd {foregroundAtStart:X}->{foregroundAtFallback:X}, formats={formats})";
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

    /// <summary>Release clipboard ownership immediately. WinForms Clipboard.Clear uses OLE and can
    /// keep ownership until the STA returns to its message loop; Chromium copies asynchronously and
    /// cannot replace that owner while conversion is synchronously waiting for it.</summary>
    private static bool ClearForCopy(int attempts = 8)
    {
        for (int i = 0; i < attempts; i++)
        {
            if (OpenClipboard(IntPtr.Zero))
            {
                try { return EmptyClipboard(); }
                finally { CloseClipboard(); }
            }
            Thread.Sleep(15 + i * 10);
        }
        return false;
    }
}
