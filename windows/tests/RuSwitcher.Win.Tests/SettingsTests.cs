using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class SettingsTests
{
    [Fact]
    public void Persisted_enum_and_feature_flags_are_loaded()
    {
        Settings settings = Settings.Deserialize("""
            {
              "Trigger": "ShiftDoubleTap",
              "ConvertWholeLine": true,
              "SmartConversion": false,
              "SoundOnSwitch": true
            }
            """);

        Assert.Equal(TriggerKind.ShiftDoubleTap, settings.Trigger);
        Assert.True(settings.ConvertWholeLine);
        Assert.False(settings.SmartConversion);
        Assert.True(settings.SoundOnSwitch);
    }
}
