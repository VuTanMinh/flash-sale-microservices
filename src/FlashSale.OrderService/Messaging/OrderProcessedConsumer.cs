using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Serilog.Context;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Consumes OrderProcessed from the Process Worker (Week 11) and closes the
/// order out: Confirmed -> Completed, the transition that was an open
/// question in docs/order-state-machine.md from Week 1 until this week.
///
/// A separate class from StockResultConsumer rather than a third queue
/// bolted onto it: that consumer exists to handle Inventory Service's two
/// stock results, and this one handles a different upstream service's single
/// completion event. Keeping one consumer per upstream integration matches
/// how the rest of this system is laid out (each service owns a consumer per
/// producer it listens to) and follows the same
/// duplication-over-premature-abstraction call already made for
/// RabbitMqOptions, which exists three times on purpose.
///
/// The idempotent state transition itself is NOT duplicated -- it reuses
/// StockResultProcessor, which despite its Week 8 name is state-agnostic:
/// it takes a target state and applies it under an Inbox check, which is
/// exactly what is needed here too.
/// </summary>
public class OrderProcessedConsumer : BackgroundService
{
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries, per RetryDelays above

    private readonly RabbitMqOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<OrderProcessedConsumer> _logger;
    private IConnection? _connection;
    private IChannel? _channel;

    public OrderProcessedConsumer(
        IOptions<RabbitMqOptions> options, IServiceScopeFactory scopeFactory, ILogger<OrderProcessedConsumer> logger)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var factory = new ConnectionFactory
        {
            HostName = _options.Connections.Default.HostName,
            Port = _options.Connections.Default.Port,
            UserName = _options.Connections.Default.UserName,
            Password = _options.Connections.Default.Password,
        };

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                _connection = await factory.CreateConnectionAsync(stoppingToken);
                _channel = await _connection.CreateChannelAsync(cancellationToken: stoppingToken);

                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.ExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.DeadLetterExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderProcessedDeadLetterQueueName, durable: true, exclusive: false,
                    autoDelete: false, cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderProcessedDeadLetterQueueName, _options.EventBus.DeadLetterExchangeName,
                    routingKey: "OrderProcessed", cancellationToken: stoppingToken);

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderProcessedQueueName, durable: true, exclusive: false, autoDelete: false,
                    arguments: new Dictionary<string, object?>
                    {
                        ["x-dead-letter-exchange"] = _options.EventBus.DeadLetterExchangeName,
                    },
                    cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderProcessedQueueName, _options.EventBus.ExchangeName,
                    routingKey: "OrderProcessed", cancellationToken: stoppingToken);

                var consumer = new AsyncEventingBasicConsumer(_channel);
                consumer.ReceivedAsync += OnMessageReceivedAsync;

                await _channel.BasicConsumeAsync(
                    _options.EventBus.OrderProcessedQueueName, autoAck: false, consumerTag: string.Empty,
                    noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);

                _logger.LogInformation(
                    "Consuming OrderProcessed from queue '{Queue}'", _options.EventBus.OrderProcessedQueueName);

                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "OrderProcessed consumer connection failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    private async Task OnMessageReceivedAsync(object sender, BasicDeliverEventArgs eventArgs)
    {
        try
        {
            var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());
            var orderProcessed = JsonSerializer.Deserialize<OrderProcessedEto>(body)
                ?? throw new InvalidOperationException("OrderProcessedEto deserialized to null.");

            using var correlationScope = LogContext.PushProperty("CorrelationId", orderProcessed.CorrelationId);

            _logger.LogInformation(
                "Received OrderProcessed {MessageId} for order {OrderId}",
                orderProcessed.MessageId, orderProcessed.OrderId);

            var outcome = await ProcessWithRetryAsync(orderProcessed);

            switch (outcome)
            {
                case ResultProcessingOutcome.Applied:
                    OrderMetrics.OrdersByOutcome.WithLabels(nameof(OrderState.Completed)).Inc();
                    _logger.LogInformation("Order {OrderId} -> Completed", orderProcessed.OrderId);
                    break;
                case ResultProcessingOutcome.OrderNotFound:
                    _logger.LogWarning(
                        "Received a completion for unknown order {OrderId}; acking without action",
                        orderProcessed.OrderId);
                    break;
                case ResultProcessingOutcome.AlreadyProcessed:
                    // Expected whenever the Process Worker replays: it derives
                    // MessageId from OrderId, so a redelivered StockReserved
                    // produces the identical completion message and the Week 9
                    // Inbox recognises it here.
                    _logger.LogInformation(
                        "OrderProcessed {MessageId} for order {OrderId} already processed; acking as no-op",
                        orderProcessed.MessageId, orderProcessed.OrderId);
                    break;
            }

            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (InvalidOrderStateTransitionException ex)
        {
            // A completion for an order that is not Confirmed -- e.g. one that
            // was Rejected. Deterministic, so retrying cannot fix it; straight
            // to the DLQ, loudly, exactly as StockResultConsumer treats the
            // same class of conflict.
            _logger.LogError(ex, "Order state conflict processing a completion event; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process completion event after retries; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
    }

    private async Task<ResultProcessingOutcome> ProcessWithRetryAsync(OrderProcessedEto orderProcessed)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
                return await StockResultProcessor.ProcessAsync(
                    dbContext, orderProcessed.OrderId, orderProcessed.MessageId, "OrderProcessed", OrderState.Completed);
            }
            catch (InvalidOrderStateTransitionException)
            {
                throw;
            }
            catch (Exception ex)
            {
                if (attempt == MaxAttempts)
                {
                    _logger.LogError(
                        ex,
                        "Failed to process OrderProcessed {MessageId} for order {OrderId} after {Attempts} attempts; routing to DLQ",
                        orderProcessed.MessageId, orderProcessed.OrderId, attempt);
                    throw;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex,
                    "Failed to process OrderProcessed {MessageId} for order {OrderId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    orderProcessed.MessageId, orderProcessed.OrderId, attempt, MaxAttempts, delay);
                await Task.Delay(delay);
            }
        }

        throw new UnreachableException(); // the loop above always returns or rethrows
    }

    public override void Dispose()
    {
        _channel?.Dispose();
        _connection?.Dispose();
        base.Dispose();
    }
}
