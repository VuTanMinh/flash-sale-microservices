namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// Bound from the "RabbitMQ" appsettings.json section. Third copy of this
/// small POCO (Order Service and Inventory Service each have their own) --
/// still deliberately duplicated rather than extracted into a shared
/// library, for the same reason given in the other two: it is a handful of
/// settings properties, and a shared messaging-configuration assembly would
/// couple three services together to save nothing.
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

        /// <summary>
        /// This service's OWN queue for StockReserved -- deliberately a
        /// different queue name from Order Service's "StockReserved" queue,
        /// both bound to the same exchange with the same "StockReserved"
        /// routing key. A direct exchange delivers a copy to every bound
        /// queue, so Order Service and the Process Worker each receive their
        /// own copy of the same event and react independently. Sharing one
        /// queue would instead make them compete for messages, and roughly
        /// half of all orders would never be processed.
        /// </summary>
        public string StockReservedQueueName { get; set; } = "ProcessWorker.StockReserved";

        public string DeadLetterExchangeName { get; set; } = "flashsale.dlx";

        public string StockReservedDeadLetterQueueName { get; set; } = "ProcessWorker.StockReserved.dlq";

        /// <summary>
        /// Overrides the routing key a dead-lettered message carries into the
        /// DLX (via x-dead-letter-routing-key on the main queue). Without
        /// this, RabbitMQ preserves the ORIGINAL routing key ("StockReserved")
        /// on dead-letter, and since flashsale.dlx is a direct exchange shared
        /// with Order Service -- whose own StockReserved.dlq is already bound
        /// to it with exactly that key -- one poison message would be copied
        /// into both services' dead-letter queues, making it impossible to
        /// tell from the DLQ alone which consumer actually failed. Rewriting
        /// the key on the way out keeps the two dead-letter streams separate
        /// while still sharing a single DLX.
        /// </summary>
        public string DeadLetterRoutingKey { get; set; } = "ProcessWorker.StockReserved";
    }
}
