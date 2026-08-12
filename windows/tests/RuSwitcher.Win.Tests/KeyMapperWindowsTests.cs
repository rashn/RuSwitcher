using RuSwitcher.Win.Core;
using RuSwitcher.Win.Native;
using Xunit;

namespace RuSwitcher.Win.Tests;

/// <summary>Guards the UTF-16 boundary of ToUnicodeEx. Without explicit Unicode marshalling,
/// Cyrillic U+043F was truncated to its low byte '?' and "привет" became "?@825B".</summary>
public class KeyMapperWindowsTests
{
    [Fact]
    public void ToUnicodeEx_preserves_non_ascii_characters()
    {
        if (!OperatingSystem.IsWindows()) return;

        IntPtr russian = LayoutSwitcher.Installed()
            .FirstOrDefault(hkl => (hkl.ToInt64() & 0x3FF) == 0x19);
        if (russian == IntPtr.Zero) return; // Russian is optional on CI images.

        uint scanCode = Win32.MapVirtualKeyExW(0x47, Win32.MAPVK_VK_TO_VSC, russian); // G key -> п
        char? translated = KeyMapper.TranslateIn(
            new TypedKey(0x47, scanCode, Shift: false, Caps: false), russian);

        Assert.Equal('п', translated);
    }
}
