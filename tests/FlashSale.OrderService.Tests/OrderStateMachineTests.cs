using System;
using FlashSale.OrderService.Entities;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Every legal transition from docs/order-state-machine.md succeeds; a
/// representative sample of illegal ones throws.
///
/// Week 11 rewrote this file along with the state machine it tests. Until
/// then Confirmed was terminal, because the Confirmed -> Processing ->
/// Completed leg had no named trigger; the Process Worker (Step 11.1) gave
/// it one, and in doing so also retired Processing and ProcessingFailed
/// entirely (see OrderState for why). So the "Confirmed is terminal for now"
/// test that used to live here is gone -- replaced by the real transition it
/// was a placeholder for -- and the illegal-target theories no longer
/// enumerate two states that no longer exist.
/// </summary>
public class OrderStateMachineTests
{
    private static Order NewPendingOrder() =>
        new(Guid.NewGuid(), "idem-key-" + Guid.NewGuid(), "product-1", 1, "corr-" + Guid.NewGuid());

    [Fact]
    public void New_order_starts_in_PendingStock()
    {
        var order = NewPendingOrder();
        Assert.Equal(OrderState.PendingStock, order.State);
        Assert.Null(order.ConfirmedOrRejectedAt);
        Assert.Null(order.CompletedAt);
    }

    [Fact]
    public void PendingStock_to_Confirmed_succeeds_and_stamps_ConfirmedOrRejectedAt()
    {
        var order = NewPendingOrder();

        order.TransitionTo(OrderState.Confirmed);

        Assert.Equal(OrderState.Confirmed, order.State);
        Assert.NotNull(order.ConfirmedOrRejectedAt);
        // Completion is a separate, later fact -- confirming stock must not
        // pre-stamp it.
        Assert.Null(order.CompletedAt);
    }

    [Fact]
    public void PendingStock_to_Rejected_succeeds_and_stamps_ConfirmedOrRejectedAt()
    {
        var order = NewPendingOrder();

        order.TransitionTo(OrderState.Rejected);

        Assert.Equal(OrderState.Rejected, order.State);
        Assert.NotNull(order.ConfirmedOrRejectedAt);
    }

    [Fact]
    public void Confirmed_to_Completed_succeeds_and_stamps_CompletedAt()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);
        var confirmedAt = order.ConfirmedOrRejectedAt;

        order.TransitionTo(OrderState.Completed);

        Assert.Equal(OrderState.Completed, order.State);
        Assert.NotNull(order.CompletedAt);
        // The earlier timestamp is a record of when stock was decided and must
        // survive the later transition unchanged -- Proposal §4d's schema is
        // only useful if each stage's time stays pinned to that stage.
        Assert.Equal(confirmedAt, order.ConfirmedOrRejectedAt);
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Completed)]
    public void PendingStock_to_anything_else_throws(OrderState illegalTarget)
    {
        var order = NewPendingOrder();

        // Completed is specifically included: an order must not skip the stock
        // decision entirely, however the completion event arrives.
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(illegalTarget));
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Rejected)]
    [InlineData(OrderState.Confirmed)]
    public void Confirmed_to_anything_but_Completed_throws(OrderState illegalTarget)
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);

        // Confirmed -> Confirmed is in this list deliberately: the absence of a
        // self-loop is what makes a redelivered StockReserved distinguishable
        // from a genuine conflict, which StockResultProcessor relies on (Week 9).
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(illegalTarget));
    }

    [Fact]
    public void Rejected_is_terminal_and_throws_on_any_transition()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Rejected);

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Confirmed));
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Completed));
    }

    [Fact]
    public void Completed_is_terminal_and_throws_on_any_transition()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);
        order.TransitionTo(OrderState.Completed);

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Completed));
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Rejected));
    }

    [Fact]
    public void Exception_reports_the_attempted_from_and_to_states()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Rejected);

        var ex = Assert.Throws<InvalidOrderStateTransitionException>(
            () => order.TransitionTo(OrderState.Completed));

        Assert.Equal(OrderState.Rejected, ex.FromState);
        Assert.Equal(OrderState.Completed, ex.ToState);
    }
}
