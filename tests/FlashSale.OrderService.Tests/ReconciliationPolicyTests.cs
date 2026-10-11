using FlashSale.OrderService.Messaging;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Week 10 box 2: the pure decision logic behind ReconciliationWorker's
/// bounded re-trigger (attempt counting and the give-up bound), exercised
/// directly with no broker and no database -- see ReconciliationPolicy's own
/// doc comment for why the logic was extracted from the worker.
/// </summary>
public class ReconciliationPolicyTests
{
    [Theory]
    [InlineData(0, 0)]
    [InlineData(1, 0)] // the original delivery only -- not a re-trigger
    [InlineData(2, 1)]
    [InlineData(3, 2)]
    [InlineData(4, 3)]
    public void PastRetriggers_counts_every_OrderPlaced_row_after_the_original(int rowCount, int expected)
    {
        Assert.Equal(expected, ReconciliationPolicy.PastRetriggers(rowCount));
    }

    [Fact]
    public void Decide_re_triggers_below_the_bound_and_skips_a_recent_re_trigger()
    {
        Assert.Equal(ReconciliationPolicy.Decision.ReTrigger, ReconciliationPolicy.Decide(0, recentlyRetriggered: false, maxAttempts: 3));
        Assert.Equal(ReconciliationPolicy.Decision.ReTrigger, ReconciliationPolicy.Decide(1, recentlyRetriggered: false, maxAttempts: 3));
        Assert.Equal(ReconciliationPolicy.Decision.ReTrigger, ReconciliationPolicy.Decide(2, recentlyRetriggered: false, maxAttempts: 3));

        // A re-trigger already written within the timeout window is skipped, not
        // fired again on every poll tick.
        Assert.Equal(ReconciliationPolicy.Decision.RecentlyReTriggered, ReconciliationPolicy.Decide(1, recentlyRetriggered: true, maxAttempts: 3));
        Assert.Equal(ReconciliationPolicy.Decision.RecentlyReTriggered, ReconciliationPolicy.Decide(2, recentlyRetriggered: true, maxAttempts: 3));
    }

    [Fact]
    public void Decide_gives_up_once_the_re_trigger_bound_is_reached_and_the_last_re_trigger_is_not_recent()
    {
        Assert.Equal(ReconciliationPolicy.Decision.GivenUp, ReconciliationPolicy.Decide(3, recentlyRetriggered: false, maxAttempts: 3));
        Assert.Equal(ReconciliationPolicy.Decision.GivenUp, ReconciliationPolicy.Decide(4, recentlyRetriggered: false, maxAttempts: 3));
    }

    [Fact]
    public void Decide_skips_a_recent_re_trigger_even_when_the_bound_is_reached()
    {
        // The bound is reached but the last re-trigger is still in its timeout
        // window: skip, so the alert never fires while a re-trigger is in flight.
        Assert.Equal(ReconciliationPolicy.Decision.RecentlyReTriggered, ReconciliationPolicy.Decide(3, recentlyRetriggered: true, maxAttempts: 3));
        Assert.Equal(ReconciliationPolicy.Decision.RecentlyReTriggered, ReconciliationPolicy.Decide(4, recentlyRetriggered: true, maxAttempts: 3));
    }
}
