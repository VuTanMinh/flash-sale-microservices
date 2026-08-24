using System;
using FlashSale.OrderService.Entities;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Every legal transition from docs/order-state-machine.md succeeds; a
/// representative sample of illegal ones throws. Confirmed/Processing/
/// Completed/ProcessingFailed currently have no legal way OUT (see
/// Order.LegalTransitions) since Confirmed->Processing's trigger is still an
/// open question — so "throws once terminal" is asserted for all of them,
/// not just Completed.
/// </summary>
public class OrderStateMachineTests
{
    private static Order NewPendingOrder() =>
        new(Guid.NewGuid(), "idem-key-" + Guid.NewGuid(), "product-1", 1);

    [Fact]
    public void New_order_starts_in_PendingStock()
    {
        var order = NewPendingOrder();
        Assert.Equal(OrderState.PendingStock, order.State);
        Assert.Null(order.ConfirmedOrRejectedAt);
    }

    [Fact]
    public void PendingStock_to_Confirmed_succeeds_and_stamps_ConfirmedOrRejectedAt()
    {
        var order = NewPendingOrder();

        order.TransitionTo(OrderState.Confirmed);

        Assert.Equal(OrderState.Confirmed, order.State);
        Assert.NotNull(order.ConfirmedOrRejectedAt);
    }

    [Fact]
    public void PendingStock_to_Rejected_succeeds_and_stamps_ConfirmedOrRejectedAt()
    {
        var order = NewPendingOrder();

        order.TransitionTo(OrderState.Rejected);

        Assert.Equal(OrderState.Rejected, order.State);
        Assert.NotNull(order.ConfirmedOrRejectedAt);
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Processing)]
    [InlineData(OrderState.Completed)]
    [InlineData(OrderState.ProcessingFailed)]
    public void PendingStock_to_anything_else_throws(OrderState illegalTarget)
    {
        var order = NewPendingOrder();

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(illegalTarget));
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Rejected)]
    [InlineData(OrderState.Processing)]
    [InlineData(OrderState.Completed)]
    [InlineData(OrderState.ProcessingFailed)]
    public void Confirmed_is_terminal_for_now_and_throws_on_any_transition(OrderState target)
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);

        // Confirmed->Processing is a real transition in docs/order-state-machine.md,
        // but its trigger is an open question there (Week 11 Process Worker) --
        // there is deliberately no code path that can perform it yet, so it
        // throws here exactly like every other target. Remove this Theory case
        // from the "throws" list, and add a dedicated success test, the day
        // that trigger actually gets implemented.
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(target));
    }

    [Fact]
    public void Rejected_is_terminal_and_throws_on_any_transition()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Rejected);

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Confirmed));
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
