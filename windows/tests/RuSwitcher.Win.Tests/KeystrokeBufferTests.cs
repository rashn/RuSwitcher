using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

/// <summary>Pure-logic tests for the keystroke buffer — the part that ports 1:1 across
/// platforms and can be verified in CI without a live Windows session.</summary>
public class KeystrokeBufferTests
{
    [Theory]
    [InlineData(0x20)] // Space
    [InlineData(0x0D)] // Enter
    [InlineData(0x09)] // Tab
    [InlineData(0x1B)] // Esc
    public void Boundaries_end_a_word(uint vk) => Assert.True(KeystrokeBuffer.IsWordBoundary(vk));

    [Theory]
    [InlineData(0x41)] // A
    [InlineData(0x08)] // Backspace
    public void Letters_and_backspace_are_not_boundaries(uint vk) =>
        Assert.False(KeystrokeBuffer.IsWordBoundary(vk));

    [Theory]
    [InlineData(0x41)] // A
    [InlineData(0x5A)] // Z
    [InlineData(0x30)] // 0
    [InlineData(0xBA)] // OEM_1 ';' — a letter in ЙЦУКЕН
    [InlineData(0xE2)] // OEM_102
    public void Typing_keys_are_buffered(uint vk) => Assert.True(KeystrokeBuffer.IsTypingKey(vk));

    [Theory]
    [InlineData(0x20)] // Space
    [InlineData(0x11)] // Ctrl
    [InlineData(0x12)] // Alt
    public void Non_typing_keys_are_ignored(uint vk) => Assert.False(KeystrokeBuffer.IsTypingKey(vk));

    [Fact]
    public void Append_then_reset_clears_the_word()
    {
        var b = new KeystrokeBuffer();
        Assert.True(b.IsEmpty);

        b.Append(new TypedKey(0x41, 0x1E, Shift: false, Caps: false));
        b.Append(new TypedKey(0x42, 0x30, Shift: true, Caps: false));
        Assert.Equal(2, b.CurrentWord.Count);
        Assert.True(b.CurrentWord[1].Shift);

        b.Reset();
        Assert.True(b.IsEmpty);
        Assert.True(b.IsLineEmpty);
    }

    [Fact]
    public void Line_buffer_keeps_spaces_and_backspace_rebuilds_the_current_word()
    {
        var b = new KeystrokeBuffer();
        var a = new TypedKey(0x41, 0x1E, Shift: false, Caps: false);
        var space = new TypedKey(KeystrokeBuffer.VK_SPACE, 0x39, Shift: false, Caps: false);
        var c = new TypedKey(0x43, 0x2E, Shift: false, Caps: false);

        b.Append(a);
        b.AppendSpace(space);
        b.Append(c);
        Assert.Equal(3, b.CurrentLine.Count);
        Assert.Single(b.CurrentWord);

        b.Backspace();
        Assert.True(b.IsEmpty);
        b.Backspace(); // remove space; the previous word becomes current again
        Assert.Single(b.CurrentWord);
        Assert.Equal(a, b.CurrentWord[0]);
    }

    [Fact]
    public void Backspace_removes_only_the_last_buffered_key()
    {
        var b = new KeystrokeBuffer();
        b.Append(new TypedKey(0x41, 0x1E, Shift: false, Caps: false));
        b.Append(new TypedKey(0x42, 0x30, Shift: false, Caps: false));

        b.Backspace();
        Assert.Single(b.CurrentWord);
        Assert.Equal(0x41u, b.CurrentWord[0].VkCode);

        b.Backspace();
        b.Backspace();
        Assert.True(b.IsEmpty);
    }

    [Theory]
    [InlineData(0x25)] // Left
    [InlineData(0x27)] // Right
    [InlineData(0x24)] // Home
    [InlineData(0x23)] // End
    [InlineData(0x2E)] // Delete
    public void Caret_and_editing_keys_invalidate_the_word(uint vk) =>
        Assert.True(KeystrokeBuffer.InvalidatesWord(vk));

    [Fact]
    public void Caret_move_reset_discards_both_word_and_line_history()
    {
        var b = new KeystrokeBuffer();
        b.Append(new TypedKey(0x47, 0x22, Shift: false, Caps: false));
        b.AppendSpace(new TypedKey(KeystrokeBuffer.VK_SPACE, 0x39, Shift: false, Caps: false));
        b.Append(new TypedKey(0x48, 0x23, Shift: false, Caps: false));

        Assert.True(KeystrokeBuffer.InvalidatesWord(KeystrokeBuffer.VK_LEFT));
        b.Reset(); // Program performs this on caret keys and mouse clicks.

        Assert.True(b.IsEmpty);
        Assert.True(b.IsLineEmpty);
    }
}
