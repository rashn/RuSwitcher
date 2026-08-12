using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class TriggerRoutingTests
{
    [Fact]
    public void Typed_word_uses_the_buffer_without_inspecting_the_application() =>
        Assert.Equal(TriggerAction.BufferedWord,
            TriggerRouting.Decide(wholeLine: false, canReconvert: false, wordKeys: 6, lineKeys: 6));

    [Fact]
    public void Whole_line_prefers_the_safe_buffer_in_every_application() =>
        Assert.Equal(TriggerAction.BufferedLine,
            TriggerRouting.Decide(wholeLine: true, canReconvert: false, wordKeys: 6, lineKeys: 12));

    [Fact]
    public void Empty_buffer_falls_back_to_selected_text() =>
        Assert.Equal(TriggerAction.SelectedText,
            TriggerRouting.Decide(wholeLine: false, canReconvert: false, wordKeys: 0, lineKeys: 0));

    [Fact]
    public void Empty_buffer_in_line_mode_falls_back_to_system_selection() =>
        Assert.Equal(TriggerAction.SystemLine,
            TriggerRouting.Decide(wholeLine: true, canReconvert: false, wordKeys: 0, lineKeys: 0));

    [Fact]
    public void Reconvert_requires_a_completely_unchanged_empty_buffer()
    {
        Assert.Equal(TriggerAction.Reconvert,
            TriggerRouting.Decide(wholeLine: false, canReconvert: true, wordKeys: 0, lineKeys: 0));
        Assert.Equal(TriggerAction.BufferedLine,
            TriggerRouting.Decide(wholeLine: true, canReconvert: true, wordKeys: 0, lineKeys: 2));
    }
}
