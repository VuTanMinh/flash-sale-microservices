using RabbitMQ.Client.Exceptions;

namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// Back-pressure for the Process Worker's publishes (post-freeze fix, 6 November 2026).
///
/// With the C3 queue bound (max-length + overflow=reject-publish) RabbitMQ refuses a
/// publish to a full queue with a basic.nack. With publisher confirmation tracking on,
/// RabbitMQ.Client 7.1.2 surfaces that as a <see cref="PublishException"/> whose
/// <see cref="PublishException.IsReturn"/> is false. An unroutable mandatory message
/// comes back as a basic.return instead, which the client reports as a
/// PublishException with IsReturn true. Only the nack means "the queue is full, try
/// again later"; a return means the topology is wrong, so it keeps the normal retry
/// ladder and dead-letter path.
///
/// Before this fix a nack was an ordinary failure: the 1, 2 and 4 s ladder ran out
/// while the queue stayed full, and the StockReserved message was dead-lettered. The
/// order then waited in Confirmed until reconciliation (300 s) picked it up. Here the
/// same publish is retried with a capped backoff and the StockReserved delivery stays
/// unacknowledged, so the Worker's prefetch and concurrency slots fill and it stops
/// taking new messages: the bound pushes back instead of making dead letters. A wait
/// longer than the configured maximum still ends in the dead-letter queue, so a queue
/// that never drains cannot hold a message forever.
/// </summary>
public static class PublishBackPressure
{
    /// <summary>Backoff between attempts: 1, 2, 4, 8, 8, ... seconds.</summary>
    public static readonly TimeSpan[] Backoff =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
    ];

    /// <summary>True only for a broker nack (a full queue with reject-publish).</summary>
    public static bool IsBrokerNack(Exception ex) => ex is PublishException { IsReturn: false };

    /// <summary>
    /// Runs <paramref name="publish"/>; while the broker nacks it, waits and retries the same
    /// publish. Waits do not count as failed attempts. Rethrows the nack once the total wait
    /// would exceed <paramref name="maxWait"/>; rethrows anything else at once.
    /// </summary>
    /// <param name="onWait">Called before each wait with the wait number (1 = first) and its length.</param>
    /// <returns>The number of waits taken.</returns>
    public static async Task<int> PublishAsync(
        Func<CancellationToken, Task> publish,
        TimeSpan maxWait,
        Action<int, TimeSpan> onWait,
        CancellationToken cancellationToken,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        delay ??= Task.Delay;
        var waited = TimeSpan.Zero;
        var waits = 0;
        while (true)
        {
            try
            {
                await publish(cancellationToken);
                return waits;
            }
            catch (Exception ex) when (IsBrokerNack(ex) && !cancellationToken.IsCancellationRequested)
            {
                var next = Backoff[Math.Min(waits, Backoff.Length - 1)];
                if (waited + next > maxWait)
                {
                    throw;
                }

                waits++;
                onWait(waits, next);
                await delay(next, cancellationToken);
                waited += next;
            }
        }
    }
}
