using System.Linq;

namespace RuSwitcher.Win.Core;

/// <summary>
/// As-you-type auto conversion — the Windows counterpart of the macOS <c>LayoutDetector.decide</c>
/// + <c>AutoSwitch</c>. On a word boundary it looks at the just-typed word and, only when the
/// dictionary is confident it was typed in the wrong layout, flips it into the opposite layout and
/// switches the keyboard. Precision over recall: at any uncertainty it does nothing (the manual
/// trigger always works). Beta, default OFF.
/// </summary>
internal static class AutoConverter
{
    /// <summary>Try to auto-convert a completed word. Runs on the message loop (NOT inside the LL-hook
    /// callback) AFTER the real Space has already been delivered to the app — so it deletes the word
    /// PLUS that trailing space (<paramref name="keys"/>.Count + 1 backspaces) and re-types the
    /// converted word followed by a space. Deferring off the hook thread keeps the callback O(1) and
    /// avoids the LowLevelHooksTimeout / silent-unhook trap (COM + SendInput must not run in-callback).
    /// Returns true if it converted; on "keep" it does nothing (the word + space stay as typed).</summary>
    public static bool TryConvertWord(IReadOnlyList<TypedKey> keys)
    {
        if (keys.Count == 0) return false;

        IntPtr sourceHkl = LayoutSwitcher.Current();
        if (LayoutSwitcher.Opposite() is not { } targetHkl) return false;

        string typed = KeyMapper.ConvertWord(keys, sourceHkl);
        string converted = KeyMapper.ConvertWord(keys, targetHkl);
        if (converted.Length == 0 || converted == typed) return false;

        string srcTag = SmartConvert.LangTag(sourceHkl);
        string tgtTag = SmartConvert.LangTag(targetHkl);
        bool caps = keys.All(k => k.Caps);

        if (!ShouldConvert(typed, converted, srcTag, tgtTag, caps)) return false;

        if (!TextInjector.Replace(backspaces: keys.Count + 1, text: converted + " ")) return false;
        LayoutSwitcher.SwitchTo(targetHkl);
        Converter.NoteAutoConversion(converted, typed, targetHkl, sourceHkl);
        return true;
    }

    // Bound to the real dictionary + settings; the decision itself lives in the pure ShouldConvertPure
    // so it can be unit-tested off Windows (no COM / no Win32).
    private static bool ShouldConvert(string typed, string converted, string srcTag, string tgtTag, bool caps) =>
        ShouldConvertPure(typed, converted, srcTag, tgtTag, caps,
            Dict.Available, Dict.IsValidWord,
            Settings.Current.NeverConvert, Settings.Current.AlwaysConvert);

    /// <summary>The verdict logic, ported from the macOS <c>LayoutDetector.decide</c>. Pure: the
    /// dictionary and exception lists are passed in, so it is fully unit-testable. Returns true only
    /// when the word should be flipped to the opposite layout.</summary>
    internal static bool ShouldConvertPure(string typed, string converted, string srcTag, string tgtTag,
        bool caps, bool dictAvailable, Func<string, string, bool> isValidWord,
        ICollection<string> never, ICollection<string> always)
    {
        string typedLc = typed.ToLowerInvariant();
        string convertedLc = converted.ToLowerInvariant();

        // Explicit overrides (checked before the soft vetoes).
        if (always.Contains(convertedLc)) return true;
        if (never.Contains(typedLc)) return false;

        // --- soft vetoes (cheap, before the dictionary) ---
        if (typed.Length < 3) return false;                 // 1–2 letters: too many cross-layout collisions
        if (!typed.All(char.IsLetter)) return false;        // digits / punctuation / URL / code / email
        if (!caps)                                          // under Caps Lock these two aren't acronyms/camelCase
        {
            if (IsAllCaps(typed)) return false;             // acronyms
            if (LooksLikeCode(typed)) return false;         // camelCase / mixed scripts
        }

        // --- Hebrew cross-script pairs (positive signal only, from the non-Hebrew side) ---
        bool srcHe = srcTag == "he", tgtHe = tgtTag == "he";
        if (srcHe || tgtHe)
        {
            string sideTag = srcHe ? tgtTag : srcTag;
            if (sideTag == "he" || !dictAvailable) return false;
            if (srcHe)
            {
                // The EN image of correct Hebrew can be "word + punctuation" and falsely pass the
                // dictionary — only feed it an all-letter image.
                if (!converted.All(char.IsLetter)) return false;
                return isValidWord(convertedLc, sideTag);
            }
            // Typed on the non-Hebrew side: never auto-convert toward Hebrew (direction unresolvable
            // without a Hebrew dictionary — precision over recall). The manual trigger still works.
            return false;
        }

        // --- common same-alphabet-swap case ---
        if (!dictAvailable) return false;
        if (!isValidWord(convertedLc, tgtTag)) return false;   // flipped form isn't a real word → keep
        if (isValidWord(typedLc, srcTag)) return false;        // typed form is already real → keep
        return true;
    }

    private static bool IsAllCaps(string s) =>
        s == s.ToUpperInvariant() && s != s.ToLowerInvariant();

    /// <summary>Looks like a code identifier: an internal capital (camelCase/PascalCase) or a mix of
    /// Latin and Cyrillic in one token — almost always code, not a word.</summary>
    private static bool LooksLikeCode(string s)
    {
        for (int i = 1; i < s.Length; i++)
            if (char.IsUpper(s[i])) return true;

        bool latin = false, cyr = false;
        foreach (char c in s)
        {
            if (c is >= 'a' and <= 'z' or >= 'A' and <= 'Z') latin = true;
            else if (c is >= 'Ѐ' and <= 'ӿ') cyr = true;
        }
        return latin && cyr;
    }
}
