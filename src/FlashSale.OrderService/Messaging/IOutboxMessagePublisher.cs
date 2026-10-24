using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace FlashSale.OrderService.Messaging;

/// <summary>One Outbox row's routing key and body, as handed to the publisher.</summary>
public sealed record OutboxMessage(string EventType, string PayloadJson);

/// <summary>
/// Publishes one outbox message and does not return until the broker has
/// actually confirmed receipt. A "the publish call didn't throw" guarantee
/// is not the same thing and is explicitly not good enough here (checklist
/// Step 6.2's warning) -- a broker that accepts a TCP write but then rejects
/// the message asynchronously would silently drop it under that weaker
/// guarantee. Implementations must not return successfully until they know
/// the broker has it.
/// </summary>
public interface IOutboxMessagePublisher
{
    Task PublishAsync(string eventType, string payloadJson, CancellationToken cancellationToken = default);

    /// <summary>
    /// Publishes the messages in order and waits for every confirm. Returns
    /// one entry per message: null when the broker confirmed that message,
    /// otherwise why it was not confirmed. Same guarantee as
    /// <see cref="PublishAsync"/>, per message; the confirms are only waited
    /// for together instead of one round trip at a time.
    /// </summary>
    Task<Exception?[]> PublishBatchAsync(IReadOnlyList<OutboxMessage> messages, CancellationToken cancellationToken = default);
}
