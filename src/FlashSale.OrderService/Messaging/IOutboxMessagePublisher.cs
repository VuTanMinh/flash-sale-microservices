using System.Threading;
using System.Threading.Tasks;

namespace FlashSale.OrderService.Messaging;

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
}
