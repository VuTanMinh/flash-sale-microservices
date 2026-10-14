using System;

namespace FlashSale.InventoryService.Entities;

/// <summary>
/// Inventory Service's own Inbox row (Week 9, docs/erd.md) -- this service's
/// own copy, symmetric with Order Service's, since each consumer needs its
/// own inbox. Deliberately a *different* idempotency layer from Redis's
/// <c>processed:{productId}</c> set (scripts/redis/reserve.lua, Week 7):
/// that one dedupes by *order id* at the business/reservation level (two
/// different messages for the same order must not both reserve stock); this
/// one dedupes by *MessageId* at the broker-delivery level (the exact same
/// physical RabbitMQ message must not be processed twice), checked before
/// the Lua script is even called. Losing either check would surface a
/// different failure mode -- see report.tex's Week 9 section for why both
/// are kept rather than treating one as redundant with the other.
/// </summary>
public class ProcessedMessage
{
    public Guid Id { get; private set; }

    public Guid MessageId { get; private set; }

    public string MessageType { get; private set; } = null!;

    public DateTime ProcessedAt { get; private set; }

    private ProcessedMessage()
    {
        // EF Core materialization only.
    }

    public ProcessedMessage(Guid id, Guid messageId, string messageType)
    {
        Id = id;
        MessageId = messageId;
        MessageType = messageType;
        ProcessedAt = DateTime.UtcNow;
    }
}
