using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Scancode + layout -> character via ToUnicodeEx — the Windows analog of the macOS
/// <c>DynamicKeyMapping</c> (Carbon UCKeyTranslate). Layout-driven, no hardcoded tables.
/// </summary>
internal static class KeyMapper
{
    /// <summary>The character a key would produce right now, in the active layout.</summary>
    public static char? Translate(uint vkCode, uint scanCode)
    {
        IntPtr hkl = GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), out _));
        return TranslateIn(new TypedKey(vkCode, scanCode, Shift: false, Caps: false), hkl);
    }

    /// <summary>Reproduce one key's character in a specific layout, honoring Shift/Caps.</summary>
    public static char? TranslateIn(TypedKey key, IntPtr hkl)
    {
        var state = new byte[256];
        if (key.Shift) state[0x10] = 0x80;               // VK_SHIFT down
        if (key.Caps) state[0x14] = 0x01;                // VK_CAPITAL toggled

        var buf = new System.Text.StringBuilder(8);
        // wFlags bit 2 (0x4): do not change the keyboard state (avoids clobbering real dead-key
        // state). Dead-key edge cases are deferred, mirroring the macOS NoDeadKeys approach.
        int n = ToUnicodeEx(key.VkCode, key.ScanCode, state, buf, buf.Capacity, 0x4, hkl);
        return n >= 1 ? buf[0] : null;
    }

    /// <summary>Convert a buffered word into the string it would be in <paramref name="targetHkl"/>.
    /// The Windows analog of <c>DynamicKeyMapping.convertKeys</c>.</summary>
    public static string ConvertWord(IReadOnlyList<TypedKey> keys, IntPtr targetHkl)
    {
        var sb = new System.Text.StringBuilder(keys.Count);
        foreach (var k in keys)
        {
            char? c = TranslateIn(k, targetHkl);
            if (c is { } ch) sb.Append(ch);
        }
        return sb.ToString();
    }

    // Character-producing keys (digits, letters, OEM punctuation) — the Windows analog of the
    // macOS keycode range used to build the char↔char map.
    private static readonly uint[] CharVks = BuildCharVks();

    private static uint[] BuildCharVks()
    {
        var list = new List<uint>();
        for (uint v = 0x30; v <= 0x39; v++) list.Add(v);          // 0-9
        for (uint v = 0x41; v <= 0x5A; v++) list.Add(v);          // A-Z
        foreach (uint v in new uint[] { 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xDB, 0xDC, 0xDD, 0xDE, 0xE2 })
            list.Add(v);                                          // OEM ;=,-./` [ \ ] ' <>
        return list.ToArray();
    }

    /// <summary>Char→char map from <paramref name="sourceHkl"/> to <paramref name="targetHkl"/> —
    /// the Windows analog of the macOS <c>DynamicKeyMapping.buildMap</c>, for converting arbitrary
    /// selected text (no keycodes). No-shift mapping wins on a collision (a key whose shifted and
    /// unshifted source chars are identical, e.g. caseless scripts) — the same guard as the macOS
    /// Hebrew case-leak fix, so lowercase isn't overwritten by the uppercase target.</summary>
    public static Dictionary<char, char> BuildPairMap(IntPtr sourceHkl, IntPtr targetHkl)
    {
        var map = new Dictionary<char, char>();
        foreach (uint vk in CharVks)
        {
            uint sc = MapVirtualKeyExW(vk, MAPVK_VK_TO_VSC, sourceHkl);
            AddPair(map, vk, sc, shift: false, sourceHkl, targetHkl);
            AddPair(map, vk, sc, shift: true, sourceHkl, targetHkl);
        }
        return map;
    }

    private static void AddPair(Dictionary<char, char> map, uint vk, uint sc, bool shift, IntPtr src, IntPtr tgt)
    {
        char? s = TranslateIn(new TypedKey(vk, sc, shift, Caps: false), src);
        char? t = TranslateIn(new TypedKey(vk, sc, shift, Caps: false), tgt);
        // Only map when the SOURCE char is a letter. Punctuation keys (EN ','→RU 'б', '.'→'ю', ';'→'ж')
        // must stay LITERAL in text/selection conversion — otherwise «ghbdtn.» → «приветю» and a
        // mistyped word ending in a period silently fails to convert (issue #15, the same rule the
        // manual last-word path applies by keeping trailing punctuation literal).
        if (s is { } sch && t is { } tch && sch != tch && char.IsLetter(sch) && !map.ContainsKey(sch))
            map[sch] = tch;
    }

    /// <summary>Convert arbitrary text from the source layout to the target layout (char by char).</summary>
    public static string ConvertText(string text, IntPtr sourceHkl, IntPtr targetHkl)
    {
        var map = BuildPairMap(sourceHkl, targetHkl);
        var sb = new System.Text.StringBuilder(text.Length);
        foreach (char c in text) sb.Append(map.TryGetValue(c, out char m) ? m : c);
        return sb.ToString();
    }
}
