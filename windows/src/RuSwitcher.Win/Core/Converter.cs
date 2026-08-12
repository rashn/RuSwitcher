using System.Windows.Forms;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Orchestrates a manual conversion of the last typed word: take the buffer, render it in the
/// opposite layout, delete + reinsert, then switch the layout — the Windows counterpart of the
/// macOS <c>AppDelegate.onAltTap</c>. A second trigger with no typing in between reverses it
/// (reconvert/undo, toggling back and forth) — the counterpart of <c>onAltReconvert</c>.
/// </summary>
internal static class Converter
{
    public static string LastDiagnostic { get; private set; } = "";
    // Last conversion, for reconvert. "_a" is what's currently on screen; "_b" is the alternative.
    // Each side carries its layout so reconvert also restores the right keyboard layout.
    private static string _aText = "";
    private static string _bText = "";
    private static IntPtr _aHkl;
    private static IntPtr _bHkl;
    private static bool _lastWasAuto;   // last conversion came from as-you-type auto (learn-from-undo)

    /// <summary>True if the last conversion can be reversed (nothing typed since).</summary>
    public static bool CanReconvert => _aText.Length > 0;

    /// <summary>Any real typing invalidates a pending reconvert (the word on screen changed).</summary>
    public static void ClearReconvert() { _aText = ""; _bText = ""; _lastWasAuto = false; }

    /// <summary>Record an auto-conversion so the trigger can reverse it — and so reversing it teaches
    /// an exception (learn-from-undo). <paramref name="onScreen"/> is what's now shown; the
    /// <paramref name="alternative"/> is the original typed word restored on undo.</summary>
    public static void NoteAutoConversion(string onScreen, string alternative, IntPtr onScreenHkl, IntPtr altHkl)
    {
        _aText = onScreen; _aHkl = onScreenHkl;
        _bText = alternative; _bHkl = altHkl;
        _lastWasAuto = true;
    }

    // Trailing keys whose char in the CURRENT layout is sentence punctuation are kept literally,
    // not converted — otherwise «ghbdtn,» would become «приветб» (the comma key is «б» in ЙЦУКЕН).
    // issue #15. The ambiguous ю/б/ж tails (e.g. «зуб» = "pe,") are left to the user, as on macOS.
    private static readonly HashSet<char> TrailingPunct = new() { ',', '.', '!', '?', ';', ':', ')' };

    /// <summary>Convert the buffered word into the opposite layout. Returns true if it acted.</summary>
    public static bool ConvertLastWord(KeystrokeBuffer buffer)
    {
        LastDiagnostic = "";
        if (buffer.IsEmpty) { LastDiagnostic = "word buffer is empty"; return false; }

        IntPtr sourceHkl = LayoutSwitcher.Current();
        if (LayoutSwitcher.Opposite() is not { } targetHkl) { LastDiagnostic = "no opposite layout"; return false; }

        // Split off trailing real punctuation (kept as typed).
        var keys = buffer.CurrentWord;
        int coreCount = keys.Count;
        var suffix = new System.Text.StringBuilder();
        while (coreCount > 0 &&
               KeyMapper.TranslateIn(keys[coreCount - 1], sourceHkl) is { } pc && TrailingPunct.Contains(pc))
        {
            suffix.Insert(0, pc);
            coreCount--;
        }
        if (coreCount == 0) { LastDiagnostic = "word contains only punctuation"; return false; }

        var core = new List<TypedKey>(coreCount);
        for (int i = 0; i < coreCount; i++) core.Add(keys[i]);
        string suf = suffix.ToString();

        string convertedCore = KeyMapper.ConvertWord(core, targetHkl);
        if (convertedCore.Length == 0) { LastDiagnostic = "target layout produced no text"; return false; }
        string originalCore = KeyMapper.ConvertWord(core, sourceHkl);  // as it was typed

        string converted = convertedCore + suf;
        string original = originalCore + suf;

        if (!TextInjector.Replace(backspaces: coreCount + suf.Length, text: converted))
        {
            LastDiagnostic = TextInjector.LastDiagnostic;
            return false;
        }
        LayoutSwitcher.SwitchTo(targetHkl);

        _aText = converted; _aHkl = targetHkl;   // now on screen
        _bText = original;  _bHkl = sourceHkl;    // the alternative (undo target)
        _lastWasAuto = false;                     // a manual convert isn't subject to learn-from-undo
        buffer.Reset();
        return true;
    }

    /// <summary>Reverse the last conversion (and toggle for a repeated trigger).</summary>
    public static bool Reconvert()
    {
        LastDiagnostic = "";
        if (_aText.Length == 0) { LastDiagnostic = "nothing to reconvert"; return false; }

        // Learn-from-undo: reversing an auto-conversion means the user rejected it — remember never to
        // auto-convert that typed word again (mirrors the macOS learn-from-undo).
        if (_lastWasAuto)
        {
            string word = LetterCoreLower(_bText);   // _bText is the original typed word being restored
            var never = Settings.Current.NeverConvert;
            if (word.Length >= 2 && !never.Contains(word))
            {
                never.Add(word);
                Settings.Current.Save();
            }
            _lastWasAuto = false;   // only teach once
        }

        if (!TextInjector.Replace(backspaces: _aText.Length, text: _bText))
        {
            LastDiagnostic = TextInjector.LastDiagnostic;
            return false;
        }
        LayoutSwitcher.SwitchTo(_bHkl);

        (_aText, _bText) = (_bText, _aText);   // toggle: a third trigger redoes the conversion
        (_aHkl, _bHkl) = (_bHkl, _aHkl);
        return true;
    }

    /// <summary>Convert the current selection via a clipboard round-trip (the counterpart of the
    /// macOS <c>convertViaClipboard</c>): Ctrl+C → convert the text char-by-char in the opposite
    /// layout → Ctrl+V, restoring the user's clipboard afterwards. One-way flip by the current
    /// layout (smart per-word conversion is a later parity step). No selection / no-op → false.
    /// MUST run on the message loop (STA), never inside the hook callback.</summary>
    public static bool ConvertSelection(bool smart)
    {
        IntPtr sourceHkl = LayoutSwitcher.Current();
        if (LayoutSwitcher.Opposite() is not { } targetHkl) return false;

        string? saved = SafeGetText();
        SafeClear();
        if (!TextInjector.SendCtrl(VK_C)) { RestoreClipboard(saved); return false; }
        Thread.Sleep(60);                       // let the focused app place the selection on the clipboard
        string sel = SafeGetText() ?? "";
        if (sel.Length == 0) { RestoreClipboard(saved); return false; }   // nothing selected

        string converted = smart
            ? SmartConvert.Selection(sel, sourceHkl, targetHkl)
            : KeyMapper.ConvertText(sel, sourceHkl, targetHkl);
        if (converted == sel) { RestoreClipboard(saved); return false; }  // no-op

        SafeSetText(converted);
        if (!TextInjector.SendCtrl(VK_V)) { RestoreClipboard(saved); return false; }
        Thread.Sleep(60);                       // let the paste happen before we restore the clipboard
        RestoreClipboard(saved);
        return true;
    }

    /// <summary>issue #24: convert the whole current line — select it with Shift+Home, then run
    /// the selection conversion. Works in normal apps and terminals that support Shift+Home
    /// selection. On a no-op, collapse the selection (End) so the line isn't left highlighted.</summary>
    public static bool ConvertLine(bool smart)
    {
        if (!TextInjector.SendShift(VK_HOME)) return false;   // select from cursor to line start
        Thread.Sleep(40);
        bool ok = ConvertSelection(smart);
        if (!ok) TextInjector.SendKey(VK_END);   // drop the selection (go to line end)
        return ok;
    }

    // Trim non-letters off both ends and lowercase — the key used for the never-convert exception list.
    private static string LetterCoreLower(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && !char.IsLetter(s[a])) a++;
        while (b > a && !char.IsLetter(s[b - 1])) b--;
        return s.Substring(a, b - a).ToLowerInvariant();
    }

    // Clipboard is shared + can be briefly locked by other apps — retry, never throw.
    private static string? SafeGetText()
    {
        try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; } catch { return null; }
    }
    private static void SafeSetText(string s)
    {
        for (int i = 0; i < 6; i++) { try { Clipboard.SetText(s); return; } catch { Thread.Sleep(15); } }
    }
    private static void SafeClear()
    {
        for (int i = 0; i < 6; i++) { try { Clipboard.Clear(); return; } catch { Thread.Sleep(15); } }
    }
    private static void RestoreClipboard(string? saved)
    {
        if (string.IsNullOrEmpty(saved)) SafeClear(); else SafeSetText(saved);
    }
}
