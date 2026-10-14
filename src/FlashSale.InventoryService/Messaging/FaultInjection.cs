using System.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Test-only fault injection for the Week 9 crash test (TP-M01,
/// docs/delivery-semantics.md). A consumer calls this between committing its
/// work and acknowledging the message. It does nothing unless both
/// FaultInjection:CrashBeforeAckConsumer and
/// FaultInjection:CrashBeforeAckCorrelationId are set and match; neither is set
/// in any appsettings file. When they match, the process is killed outright, so
/// the message stays unacknowledged and the broker redelivers it.
/// </summary>
public static class FaultInjection
{
    public static void CrashBeforeAckIfTargeted(
        IConfiguration configuration, string consumer, string? correlationId, ILogger logger)
    {
        var targetConsumer = configuration["FaultInjection:CrashBeforeAckConsumer"];
        var targetCorrelationId = configuration["FaultInjection:CrashBeforeAckCorrelationId"];
        if (string.IsNullOrEmpty(targetConsumer) || string.IsNullOrEmpty(targetCorrelationId) ||
            targetConsumer != consumer || targetCorrelationId != correlationId)
        {
            return;
        }

        logger.LogWarning(
            "Fault injection: {Consumer} committed the message for {CorrelationId}; killing the process before ack",
            consumer, correlationId);
        Serilog.Log.CloseAndFlush();
        Process.GetCurrentProcess().Kill();
    }
}
