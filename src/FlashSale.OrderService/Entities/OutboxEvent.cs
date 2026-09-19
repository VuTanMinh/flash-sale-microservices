using System;
using System.Text.Json;
using FlashSale.EventContracts;

namespace FlashSale.OrderService.Entities;

/// <summary>
/// The Transactional Outbox row (Week 6, docs/erd.md). Written in the same
/// DbContext.SaveChanges call as the Order it describes -- that single fact
/// is the entire point of the pattern (see OrdersController.CreateOrderAsync):
/// either both rows commit together, or neither does, so the order's
/// existence and its "needs an OrderPlaced event" fact can never disagree.
/// </summary>
public class OutboxEvent
{
    public Guid Id { get; private set; }

    public Guid OrderId { get; private set; }

    public string EventType { get; private set; } = null!;

    /// <summary>JSON-serialized ETO body (see FlashSale.EventContracts). Stored as
    /// jsonb in Postgres -- see OrderServiceDbContext's column configuration.</summary>
    public string Payload { get; private set; } = null!;

    public bool Published { get; private set; }

    public DateTime CreatedAt { get; private set; }

    public DateTime? PublishedAt { get; private set; }

    private OutboxEvent()
    {
        // EF Core materialization only.
    }

    public OutboxEvent(Guid id, Guid orderId, string eventType, string payload)
    {
        Id = id;
        OrderId = orderId;
        EventType = eventType;
        Payload = payload;
        Published = false;
        CreatedAt = DateTime.UtcNow;
    }

    /// <summary>
    /// Builds the OrderPlaced outbox row for a just-created order. A fresh
    /// MessageId is minted here, at write time -- this is the broker-message
    /// idempotency key the Week 9 Inbox pattern will check against, and it
    /// has to be decided once, durably, not regenerated on every publish
    /// retry (that would defeat the point of it).
    /// </summary>
    public static OutboxEvent ForOrderPlaced(Order order)
    {
        var eto = new OrderPlacedEto
        {
            OrderId = order.Id,
            ProductId = order.ProductId,
            Quantity = order.Quantity,
            MessageId = Guid.NewGuid(),
            // Carried from the order, not regenerated -- this is the point at
            // which the request's correlation id leaves Order Service and
            // becomes traceable across the other two (Week 11, Step 11.2).
            CorrelationId = order.CorrelationId,
        };

        return new OutboxEvent(Guid.NewGuid(), order.Id, "OrderPlaced", JsonSerializer.Serialize(eto));
    }

    /// <summary>
    /// Only call this after the broker has actually confirmed receipt
    /// (OutboxPublisherWorker awaits a publisher-confirmed BasicPublishAsync
    /// before calling this) -- marking a row published on anything weaker
    /// (e.g. "the publish call didn't throw" without confirms) can silently
    /// drop messages if the broker rejects asynchronously.
    /// </summary>
    public void MarkPublished()
    {
        Published = true;
        PublishedAt = DateTime.UtcNow;
    }
}
