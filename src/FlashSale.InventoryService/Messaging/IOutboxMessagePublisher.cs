using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace FlashSale.InventoryService.Messaging;

/// <summary>One Outbox row's routing key and body, as handed to the publisher.</summary>
public sealed record OutboxMessage(string EventType, string PayloadJson);

/// <summary>
/// Same contract and same reasoning as Order Service's own
/// IOutboxMessagePublisher (Week 6): does not return until the broker has
/// actually confirmed receipt, not merely once the publish call didn't throw.
/// </summary>
public interface IOutboxMessagePublisher
{
    Task PublishAsync(string eventType, string payloadJson, CancellationToken cancellationToken = default);

    /// <summary>
    /// Publishes the messages in order and waits for every confirm. Returns
    /// one entry per message: null when the broker confirmed it, otherwise
    /// why it was not confirmed.
    /// </summary>
    Task<Exception?[]> PublishBatchAsync(IReadOnlyList<OutboxMessage> messages, CancellationToken cancellationToken = default);
}
