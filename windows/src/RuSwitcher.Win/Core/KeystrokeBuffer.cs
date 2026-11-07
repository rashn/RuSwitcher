namespace RuSwitcher.Win.Core;

/// <summary>One captured key press: virtual-key + scancode, plus the modifier state
/// needed to reproduce the character in another layout. The Windows TypedKey.</summary>
public readonly record struct TypedKey(uint VkCode, uint ScanCode, bool Shift, bool Caps);

/// <summary>
/// Buffer of the word being typed — the Windows counterpart of the macOS
/// <c>KeyboardMonitor.currentWordKeys</c>. Pure logic (no Win32) so it is unit-tested.
/// </summary>
public sealed class KeystrokeBuffer
{
    private readonly List<TypedKey> _current = new();

    public IReadOnlyList<TypedKey> CurrentWord => _current;
    public bool IsEmpty => _current.Count == 0;

    public void Append(TypedKey key) => _current.Add(key);
    public void Reset() => _current.Clear();

    /// <summary>Manual Backspace: drop the last buffered key so the buffer keeps mirroring the
    /// screen — converting with a stale buffer re-types the deleted keys too («dsk,…» after a
    /// typo + Backspace became «вылбылетает»). The macOS monitor does the same (issue #21).</summary>
    public void PopLast()
    {
        if (_current.Count > 0) _current.RemoveAt(_current.Count - 1);
    }

    /// <summary>Keys that end a word (and clear the buffer): space, Enter, Tab, Esc.</summary>
    public static bool IsWordBoundary(uint vkCode) =>
        vkCode is VK_SPACE or VK_RETURN or VK_TAB or VK_ESCAPE;

    /// <summary>A key that produces a letter we should buffer (rough MVP filter:
    /// A–Z virtual keys and OEM punctuation that layouts map to letters).</summary>
    public static bool IsTypingKey(uint vkCode) =>
        (vkCode >= 0x41 && vkCode <= 0x5A)   // A–Z
        || (vkCode >= 0x30 && vkCode <= 0x39) // 0–9
        || (vkCode >= 0xBA && vkCode <= 0xE2); // OEM keys (;=,-./`[\]' etc. — letters in ЙЦУКЕН)

    public const uint VK_BACK = 0x08;
    public const uint VK_TAB = 0x09;
    public const uint VK_RETURN = 0x0D;
    public const uint VK_ESCAPE = 0x1B;
    public const uint VK_SPACE = 0x20;
}
