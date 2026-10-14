using System;
using System.Security.Cryptography;
using Volo.Abp.EventBus;

namespace FlashSale.EventContracts;

/// <summary>
/// Published by the Process Worker (Week 11 box 2) when it begins work on a
/// reserved order: before its deterministic delay, with publisher confirms and
/// a routed publish, exactly like <see cref="OrderProcessedEto"/>. Consumed by
/// Order Service to transition Confirmed -> Processing
/// (docs/order-state-machine.md).
///
/// <see cref="MessageId"/> is NOT the OrderId (which <see cref="OrderProcessedEto"/>
/// uses). It is derived deterministically from the OrderId with
/// <see cref="DeriveMessageId"/>, so a redelivered StockReserved regenerates the
/// same start MessageId and Order Service's Week 9 Inbox dedupes it — the same
/// idempotency-without-a-store trick the completion event uses, but with a
/// *distinct* identity so the Inbox can tell a start event apart from the
/// completion it precedes (a shared OrderId would let the completion suppress
/// the start event, per the 03C cross-cutting rule).
/// </summary>
[EventName("FlashSale.ProcessWorker.OrderProcessingStarted")]
public class OrderProcessingStartedEto
{
    /// <summary>
    /// Fixed namespace GUID for the name-based (v5-style, SHA-1) derivation of
    /// <see cref="MessageId"/> from <see cref="OrderId"/>. Kept as a constant so
    /// both the derivation and any independent re-implementation (e.g. the
    /// TP-P02 verifier) can reproduce the same value. See docs/event-contract.md.
    /// </summary>
    public static readonly Guid MessageIdNamespace = new("9e1b5c2a-3d4f-4a6b-8c7d-0e9f1a2b3c4d");

    public Guid OrderId { get; set; }

    /// <summary>
    /// Derived deterministically from <see cref="OrderId"/> (never a fresh Guid,
    /// never the OrderId itself). See the class comment.
    /// </summary>
    public Guid MessageId { get; set; }

    /// <summary>Carried through from the StockReserved event that triggered this one.</summary>
    public string CorrelationId { get; set; } = null!;

    /// <summary>
    /// When the Worker began processing (before its delay). The same instant is
    /// later copied onto <see cref="OrderProcessedEto.ProcessingStartedAt"/> so
    /// an out-of-order completion can record the implied Processing step with
    /// the Worker's start time.
    /// </summary>
    public DateTime StartedAt { get; set; }

    /// <summary>
    /// Name-based (v5-style) UUID: SHA-1 over the fixed namespace GUID bytes +
    /// the OrderId bytes, truncated to 16 bytes with the version-5 and
    /// RFC 4122 variant bits set. Deterministic and stable for a given OrderId.
    /// </summary>
    public static Guid DeriveMessageId(Guid orderId)
    {
        var namespaceBytes = MessageIdNamespace.ToByteArray();
        var nameBytes = orderId.ToByteArray();
        var buffer = new byte[namespaceBytes.Length + nameBytes.Length];
        namespaceBytes.CopyTo(buffer, 0);
        nameBytes.CopyTo(buffer, namespaceBytes.Length);

        var hash = SHA1.HashData(buffer);
        var uuid = new byte[16];
        Array.Copy(hash, uuid, 16);

        uuid[6] = (byte)((uuid[6] & 0x0F) | 0x50); // version 5
        uuid[8] = (byte)((uuid[8] & 0x3F) | 0x80); // RFC 4122 variant

        return new Guid(uuid);
    }
}
