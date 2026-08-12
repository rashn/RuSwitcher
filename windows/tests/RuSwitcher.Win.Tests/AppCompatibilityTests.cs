using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class AppCompatibilityTests
{
    [Theory]
    [InlineData("WindowsTerminal")]
    [InlineData("cmd")]
    [InlineData("pwsh")]
    [InlineData("wezterm")]
    public void Known_terminal_processes_use_the_buffered_line_path(string name) =>
        Assert.True(AppCompatibility.IsTerminalProcessName(name));

    [Theory]
    [InlineData("notepad")]
    [InlineData("chrome")]
    [InlineData("winword")]
    public void Document_apps_keep_the_selection_path(string name) =>
        Assert.False(AppCompatibility.IsTerminalProcessName(name));

    [Theory]
    [InlineData("chrome")]
    [InlineData("msedge")]
    [InlineData("Code")]
    [InlineData("discord")]
    public void Chromium_and_electron_apps_skip_wm_copy(string name) =>
        Assert.True(AppCompatibility.UsesKeyboardCopyProcessName(name));

    [Theory]
    [InlineData("notepad")]
    [InlineData("winword")]
    public void Native_editors_prefer_wm_copy(string name) =>
        Assert.False(AppCompatibility.UsesKeyboardCopyProcessName(name));
}
