using System;

namespace FlashSale.OrderService.Entities;

/// <summary>
/// Order Service's own Inbox row (Week 9, docs/erd.md). Distinct from the
/// client-supplied Idempotency-Key on <see cref="Order"/>: that dedupes
/// duplicate *client submissions* of the same logical request; this dedupes
/// duplicate *broker deliveries* of the same physical RabbitMQ message
/// (StockReserved/StockRejected), identified by the ETO's own MessageId
/// (FlashSale.EventContracts). At-least-once delivery is what RabbitMQ
/// guarantees; this table plus the unique constraint on MessageId is what
/// turns that into effectively-once *side effects* on the order's state.
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
