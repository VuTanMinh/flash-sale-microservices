namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Bound from the "RabbitMQ" appsettings.json section. Deliberately shaped
/// like Volo.Abp.EventBus.RabbitMQ's own AbpRabbitMqOptions/
/// AbpRabbitMqEventBusOptions JSON convention (Connections:Default:HostName,
/// EventBus:ExchangeName) for familiarity -- but this is our own small POCO,
/// not that package. See Messaging/RabbitMqOutboxPublisher.cs for why: that
/// package's options don't expose a documented way to enable publisher
/// confirms (checklist Step 6.3 explicitly asks to verify this rather than
/// assume it), and depending on a whole ABP module for a settings-binding
/// convenience we can get from a five-property class would repeat the same
/// "module pulled in but barely used" pattern flagged as a cleanup item in
/// Week 4's API contract review.
/// </summary>
public class RabbitMqOptions
{
    public ConnectionOptions Connections { get; set; } = new();

    public EventBusOptions EventBus { get; set; } = new();

    public class ConnectionOptions
    {
        public ConnectionSettings Default { get; set; } = new();
    }

    public class ConnectionSettings
    {
        public string HostName { get; set; } = "localhost";
        public int Port { get; set; } = 5672;
        public string UserName { get; set; } = "guest";
        public string Password { get; set; } = "guest";
    }

    public class EventBusOptions
    {
        public string ExchangeName { get; set; } = "flashsale.order.exchange";

        /// <summary>Queues this service consumes results from (Week 8) --
        /// one queue per event type, each bound with that type as its
        /// routing key, matching how OutboxPublisherWorker publishes.</summary>
        public string StockReservedQueueName { get; set; } = "StockReserved";
        public string StockRejectedQueueName { get; set; } = "StockRejected";

        /// <summary>Dead-letter exchange (Week 10, Step 10.2) -- see Inventory
        /// Service's own RabbitMqOptions for the fuller reasoning; same idea,
        /// separate exchange per service rather than a shared one, matching
        /// how every other messaging primitive in this project is duplicated
        /// per service instead of shared.</summary>
        public string DeadLetterExchangeName { get; set; } = "flashsale.dlx";

        public string StockReservedDeadLetterQueueName { get; set; } = "StockReserved.dlq";
        public string StockRejectedDeadLetterQueueName { get; set; } = "StockRejected.dlq";
    }
}
