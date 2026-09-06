namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Bound from the "RabbitMQ" appsettings.json section. Same shape as, but a
/// separate class from, Order Service's own RabbitMqOptions -- this is a
/// five-property POCO, not shared infrastructure, and duplicating it keeps
/// each service's messaging code self-contained rather than introducing a
/// cross-service dependency for something this small (see Order Service's
/// own RabbitMqOptions.cs for the fuller reasoning against depending on
/// Volo.Abp.EventBus.RabbitMQ for this).
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

        /// <summary>The queue this service consumes OrderPlaced from -- the
        /// same queue manually declared for verification in Week 6; this
        /// consumer now owns declaring and binding it going forward.</summary>
        public string OrderPlacedQueueName { get; set; } = "OrderPlaced";
    }
}
