using System.Threading;
using System.Threading.Tasks;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Same contract and same reasoning as Order Service's own
/// IOutboxMessagePublisher (Week 6): does not return until the broker has
/// actually confirmed receipt, not merely once the publish call didn't throw.
/// </summary>
public interface IOutboxMessagePublisher
{
    Task PublishAsync(string eventType, string payloadJson, CancellationToken cancellationToken = default);
}
