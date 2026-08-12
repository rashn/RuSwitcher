using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class MultilineConversionTests
{
    [Fact]
    public void Conversion_preserves_crlf_lf_tabs_and_blank_lines()
    {
        if (!OperatingSystem.IsWindows()) return;
        IntPtr english = LayoutSwitcher.Installed()
            .FirstOrDefault(hkl => (hkl.ToInt64() & 0x3FF) == 0x09);
        IntPtr russian = LayoutSwitcher.Installed()
            .FirstOrDefault(hkl => (hkl.ToInt64() & 0x3FF) == 0x19);
        if (english == IntPtr.Zero || russian == IntPtr.Zero) return;

        string converted = KeyMapper.ConvertText("ghbdtn\r\n\r\nмир\tghbdtn\n", english, russian);

        Assert.Equal("привет\r\n\r\nмир\tпривет\n", converted);
    }
}
