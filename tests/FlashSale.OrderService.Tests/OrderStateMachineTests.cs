using System;
using FlashSale.OrderService.Entities;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Every legal transition from docs/order-state-machine.md succeeds and stamps
/// the right order timestamp; the illegal ones throw.
///
/// Week 11 box 2 promoted Processing from a declared-but-absent state to a real
/// one: Confirmed -> Completed was split into Confirmed -> Processing ->
/// Completed, driven by a new OrderProcessingStarted event plus the existing
/// OrderProcessed event. The full transition matrix (legal and illegal) lives in
/// OrderStateBehaviourTests; this class pins the timestamp stamps and the
/// representative illegal cases, including the now-illegal Confirmed -> Completed
/// shortcut and the terminal ProcessingFailed.
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
        Assert.Null(order.CompletedAt);
    }

    [Fact]
    public void Confirmed_to_Processing_succeeds_without_stamping_CompletedAt()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);

        order.TransitionTo(OrderState.Processing);

        Assert.Equal(OrderState.Processing, order.State);
        // Processing has no order timestamp column (docs/order-state-machine.md
        // keeps the existing columns as they are): its history row carries the
        // time, not a column on the order.
        Assert.Null(order.CompletedAt);
    }

    [Fact]
    public void Processing_to_Completed_succeeds_and_stamps_CompletedAt()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);
        order.TransitionTo(OrderState.Processing);
        var confirmedAt = order.ConfirmedOrRejectedAt;

        order.TransitionTo(OrderState.Completed);

        Assert.Equal(OrderState.Completed, order.State);
        Assert.NotNull(order.CompletedAt);
        // The earlier timestamp is a record of when stock was decided and must
        // survive the later transitions unchanged -- Proposal §4d's schema is
        // only useful if each stage's time stays pinned to that stage.
        Assert.Equal(confirmedAt, order.ConfirmedOrRejectedAt);
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Processing)]
    [InlineData(OrderState.Completed)]
    [InlineData(OrderState.ProcessingFailed)]
    public void PendingStock_to_anything_but_Confirmed_or_Rejected_throws(OrderState illegalTarget)
    {
        var order = NewPendingOrder();

        // Processing/Completed are included: an order must not skip the stock
        // decision, however the worker events arrive.
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(illegalTarget));
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Rejected)]
    [InlineData(OrderState.Confirmed)]
    [InlineData(OrderState.ProcessingFailed)]
    public void Confirmed_to_anything_but_Processing_throws(OrderState illegalTarget)
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);

        // Confirmed -> Confirmed is in this list deliberately: the absence of a
        // self-loop is what makes a redelivered StockReserved distinguishable
        // from a genuine conflict, which StockResultProcessor relies on (Week 9).
        // Confirmed -> Completed is also illegal now: it must go through
        // Processing (the implied completion applies both legs, but via
        // TransitionTo(Processing) then TransitionTo(Completed), never directly).
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(illegalTarget));
    }

    [Theory]
    [InlineData(OrderState.PendingStock)]
    [InlineData(OrderState.Confirmed)]
    [InlineData(OrderState.Rejected)]
    [InlineData(OrderState.Processing)]
    [InlineData(OrderState.ProcessingFailed)]
    public void Processing_to_anything_but_Completed_throws(OrderState illegalTarget)
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);
        order.TransitionTo(OrderState.Processing);

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(illegalTarget));
    }

    [Fact]
    public void Rejected_is_terminal_and_throws_on_any_transition()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Rejected);

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Confirmed));
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Processing));
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Completed));
    }

    [Fact]
    public void Completed_is_terminal_and_throws_on_any_transition()
    {
        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);
        order.TransitionTo(OrderState.Processing);
        order.TransitionTo(OrderState.Completed);

        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Completed));
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Rejected));
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.Processing));
    }

    [Fact]
    public void ProcessingFailed_is_declared_but_unreachable()
    {
        // ProcessingFailed is terminal and unreachable by design (success-only
        // Worker): no event in scope produces it, so no legal transition targets
        // it -- every reachable state refuses TransitionTo(ProcessingFailed)
        // (covered by the matrix test in OrderStateBehaviourTests). Its outbound
        // terminality is structural (LegalTransitions[ProcessingFailed] = [])
        // and is documented in docs/order-state-machine.md. This test pins that
        // the value exists in the enum, and that nothing can reach it.
        Assert.True(Enum.IsDefined(typeof(OrderState), OrderState.ProcessingFailed));

        var order = NewPendingOrder();
        order.TransitionTo(OrderState.Confirmed);
        order.TransitionTo(OrderState.Processing);
        Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(OrderState.ProcessingFailed));
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
