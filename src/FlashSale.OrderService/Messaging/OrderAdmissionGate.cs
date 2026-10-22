using System.Threading;
using Microsoft.Extensions.Options;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// C3 admission gate (Week 12 box 1). A singleton SemaphoreSlim sized from
/// Admission:MaxConcurrentNewOrders. TryEnter waits zero: a brand-new order is
/// either admitted now or refused with 503, it never queues behind the limit.
/// </summary>
public sealed class OrderAdmissionGate
{
    private readonly SemaphoreSlim _slots;

    public OrderAdmissionGate(IOptions<AdmissionOptions> options)
    {
        var max = options.Value.MaxConcurrentNewOrders;
        _slots = new SemaphoreSlim(max, max);
    }

    public bool TryEnter() => _slots.Wait(0);

    public void Release() => _slots.Release();
}
