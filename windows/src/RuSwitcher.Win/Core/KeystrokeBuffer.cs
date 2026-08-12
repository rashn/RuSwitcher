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
    private readonly List<TypedKey> _line = new();

    public IReadOnlyList<TypedKey> CurrentWord => _current;
    public IReadOnlyList<TypedKey> CurrentLine => _line;
    public bool IsEmpty => _current.Count == 0;
    public bool IsLineEmpty => _line.Count == 0;

    public void Append(TypedKey key)
    {
        _current.Add(key);
        _line.Add(key);
    }

    /// <summary>Keep a typed space in the current-line buffer while starting a new word.</summary>
    public void AppendSpace(TypedKey key)
    {
        _line.Add(key);
        _current.Clear();
    }

    public void Backspace()
    {
        if (_line.Count == 0) return;
        _line.RemoveAt(_line.Count - 1);
        RebuildCurrentWord();
    }
    public void Reset()
    {
        _current.Clear();
        _line.Clear();
    }

    private void RebuildCurrentWord()
    {
        _current.Clear();
        int start = _line.Count;
        while (start > 0 && _line[start - 1].VkCode != VK_SPACE) start--;
        for (int i = start; i < _line.Count; i++) _current.Add(_line[i]);
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

    /// <summary>Keys that move the caret or alter text in a way the word buffer cannot mirror.</summary>
    public static bool InvalidatesWord(uint vkCode) => vkCode is
        VK_DELETE or VK_INSERT or VK_HOME or VK_END or VK_LEFT or VK_UP or VK_RIGHT or VK_DOWN
        or VK_PRIOR or VK_NEXT;

    public const uint VK_BACK = 0x08;
    public const uint VK_TAB = 0x09;
    public const uint VK_RETURN = 0x0D;
    public const uint VK_ESCAPE = 0x1B;
    public const uint VK_SPACE = 0x20;
    public const uint VK_PRIOR = 0x21;
    public const uint VK_NEXT = 0x22;
    public const uint VK_END = 0x23;
    public const uint VK_HOME = 0x24;
    public const uint VK_LEFT = 0x25;
    public const uint VK_UP = 0x26;
    public const uint VK_RIGHT = 0x27;
    public const uint VK_DOWN = 0x28;
    public const uint VK_INSERT = 0x2D;
    public const uint VK_DELETE = 0x2E;
}
