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
        if (!IsTargeted(configuration, consumer, correlationId))
        {
            return;
        }

        logger.LogWarning(
            "Fault injection: {Consumer} committed the message for {CorrelationId}; killing the process before ack",
            consumer, correlationId);
        Serilog.Log.CloseAndFlush();
        Process.GetCurrentProcess().Kill();
    }

    /// <summary>
    /// Midterm review (the untested dual-write gap): kills the process after
    /// reserve.lua took the unit in Redis and before the PostgreSQL save that
    /// records the result and the Inbox row. Targeted with
    /// CrashBeforeAckConsumer = "OrderPlaced.AfterReserve". The redelivered
    /// message must then get DUPLICATE from Lua and write the missing result
    /// without a second deduction (docs/delivery-semantics.md).
    /// </summary>
    public static void CrashAfterReserveIfTargeted(IConfiguration configuration, string? correlationId, ILogger logger)
    {
        if (!IsTargeted(configuration, "OrderPlaced.AfterReserve", correlationId))
        {
            return;
        }

        logger.LogWarning(
            "Fault injection: OrderPlaced reserved in Redis for {CorrelationId}; killing the process before the database save",
            correlationId);
        Serilog.Log.CloseAndFlush();
        Process.GetCurrentProcess().Kill();
    }

    private static bool IsTargeted(IConfiguration configuration, string consumer, string? correlationId)
    {
        var targetConsumer = configuration["FaultInjection:CrashBeforeAckConsumer"];
        var targetCorrelationId = configuration["FaultInjection:CrashBeforeAckCorrelationId"];
        return !string.IsNullOrEmpty(targetConsumer) && !string.IsNullOrEmpty(targetCorrelationId) &&
            targetConsumer == consumer && targetCorrelationId == correlationId;
    }
}
