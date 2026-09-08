using System;

namespace FlashSale.InventoryService.Entities;

/// <summary>
/// Inventory Service's own Outbox row for StockReserved/StockRejected
/// (checklist Step 8.1) -- deliberately not skipped just because this is
/// "the smaller half" of the system.
///
/// This closes a gap that's genuinely harder than Order Service's Week 6
/// outbox: there, the business fact (an order exists) and the "needs
/// publishing" fact both live in the same Postgres database, so one
/// SaveChanges call makes them atomic. Here, the business fact (stock was
/// reserved) lives in Redis -- mutated by reserve.lua -- and the "needs
/// publishing" fact lives in Postgres. Two different data stores cannot be
/// wrapped in one transaction, so a crash between "Redis says reserved" and
/// "outbox row written" is a real possibility, not a hypothetical.
///
/// The fix: OrderId is unique here, and OrderPlacedConsumer treats "ensure
/// an outbox row exists for this order" as idempotent, keyed on that
/// uniqueness -- including on a Lua DUPLICATE result (which only occurs
/// when a prior attempt already reserved the stock in Redis, so it means
/// "make sure the outbox row exists," not "skip, already handled"). A
/// redelivered OrderPlaced message can safely call this path again with no
/// risk of publishing StockReserved twice: the second attempt finds the row
/// already there and does nothing.
/// </summary>
public class OutboxEvent
{
    public Guid Id { get; private set; }

    public Guid OrderId { get; private set; }

    public string EventType { get; private set; } = null!;

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

    public void MarkPublished()
    {
        Published = true;
        PublishedAt = DateTime.UtcNow;
    }
}
