using FlashSale.ProcessWorker.Messaging;
using RabbitMQ.Client.Exceptions;

namespace FlashSale.ProcessWorker.Tests;

/// <summary>
/// The Worker's back-pressure classification and waiting (post-freeze fix): a broker
/// nack (full queue, reject-publish) is waited out without consuming attempts; a
/// return (unroutable) or any other error is rethrown at once, to the normal retry
/// ladder and dead-letter path.
/// </summary>
public class PublishBackPressureTests
{
    private static PublishException Nack() => new(publishSequenceNumber: 1, isReturn: false);
    private static PublishException Return() => new(publishSequenceNumber: 1, isReturn: true);

    private static Task NoDelay(TimeSpan _, CancellationToken __) => Task.CompletedTask;

    [Fact]
    public void A_broker_nack_is_back_pressure()
    {
        Assert.True(PublishBackPressure.IsBrokerNack(Nack()));
    }

    [Fact]
    public void A_return_or_any_other_error_is_not_back_pressure()
    {
        Assert.False(PublishBackPressure.IsBrokerNack(Return()));
        Assert.False(PublishBackPressure.IsBrokerNack(new InvalidOperationException("routing check failed")));
        Assert.False(PublishBackPressure.IsBrokerNack(new TimeoutException()));
    }

    [Fact]
    public async Task Nacks_are_waited_out_with_the_backoff_and_the_publish_then_succeeds()
    {
        var calls = 0;
        var waits = new List<(int Wait, TimeSpan Delay)>();
        var taken = await PublishBackPressure.PublishAsync(
            _ => ++calls <= 6 ? throw Nack() : Task.CompletedTask,
            TimeSpan.FromMinutes(10),
            (w, d) => waits.Add((w, d)),
            CancellationToken.None,
            NoDelay);

        Assert.Equal(7, calls);
        Assert.Equal(6, taken);
        Assert.Equal(new[] { 1, 2, 4, 8, 8, 8 }, waits.Select(x => (int)x.Delay.TotalSeconds));
        Assert.Equal(new[] { 1, 2, 3, 4, 5, 6 }, waits.Select(x => x.Wait));
    }

    [Fact]
    public async Task A_return_is_rethrown_at_once_without_waiting()
    {
        var waits = 0;
        var ex = await Assert.ThrowsAsync<PublishException>(() => PublishBackPressure.PublishAsync(
            _ => throw Return(), TimeSpan.FromMinutes(10), (_, _) => waits++, CancellationToken.None, NoDelay));
        Assert.True(ex.IsReturn);
        Assert.Equal(0, waits);
    }

    [Fact]
    public async Task Another_error_is_rethrown_at_once_without_waiting()
    {
        var waits = 0;
        await Assert.ThrowsAsync<InvalidOperationException>(() => PublishBackPressure.PublishAsync(
            _ => throw new InvalidOperationException("x"), TimeSpan.FromMinutes(10), (_, _) => waits++, CancellationToken.None, NoDelay));
        Assert.Equal(0, waits);
    }

    [Fact]
    public async Task The_nack_is_rethrown_once_the_wait_cap_would_be_exceeded()
    {
        // cap 20 s: waits 1 + 2 + 4 + 8 = 15 s fit, the next 8 s would make 23 s
        var waits = new List<TimeSpan>();
        var ex = await Assert.ThrowsAsync<PublishException>(() => PublishBackPressure.PublishAsync(
            _ => throw Nack(), TimeSpan.FromSeconds(20), (_, d) => waits.Add(d), CancellationToken.None, NoDelay));
        Assert.False(ex.IsReturn);
        Assert.Equal(15, waits.Sum(d => d.TotalSeconds));
    }

    [Fact]
    public async Task A_cancelled_host_does_not_keep_waiting()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAsync<PublishException>(() => PublishBackPressure.PublishAsync(
            _ => throw Nack(), TimeSpan.FromMinutes(10), (_, _) => { }, cts.Token, NoDelay));
    }
}
