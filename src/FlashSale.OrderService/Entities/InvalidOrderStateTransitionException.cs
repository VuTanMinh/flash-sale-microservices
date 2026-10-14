using System;

namespace FlashSale.OrderService.Entities;

/// <summary>
/// Thrown by <see cref="Order.TransitionTo"/> for any transition not listed
/// in <see cref="Order.LegalTransitions"/> — an illegal transition must throw,
/// not silently set the state field to whatever was asked for (checklist
/// Step 5.3).
/// </summary>
public class InvalidOrderStateTransitionException : Exception
{
    public OrderState FromState { get; }
    public OrderState ToState { get; }

    public InvalidOrderStateTransitionException(OrderState fromState, OrderState toState)
        : base($"Cannot transition order from '{fromState}' to '{toState}'.")
    {
        FromState = fromState;
        ToState = toState;
    }
}
