using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class InputSafetyTests
{
    [Fact]
    public void Native_password_style_is_protected()
    {
        Assert.True(InputSafety.IsPasswordStyle(0x20));
        Assert.True(InputSafety.IsPasswordStyle(unchecked((int)0x50010020)));
        Assert.False(InputSafety.IsPasswordStyle(unchecked((int)0x50010080)));
    }
}
