// Broker-level check for docs/outbox.md "Routed confirmation": with the same
// channel settings the publishers use (publisher confirmations + tracking,
// mandatory: true), an unroutable message must surface as a PublishException
// with IsReturn = true, which the Outbox worker treats as "not published".
// Usage: dotnet run --project tests/BrokerProbe -- <port> <user> <password>
using RabbitMQ.Client;
using RabbitMQ.Client.Exceptions;

var port = int.Parse(args[0]);
var factory = new ConnectionFactory { HostName = "localhost", Port = port, UserName = args[1], Password = args[2] };
await using var connection = await factory.CreateConnectionAsync();
var options = new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true);
await using var channel = await connection.CreateChannelAsync(options);
const string exchange = "verify-publication.probe";
await channel.ExchangeDeclareAsync(exchange, ExchangeType.Direct, durable: false, autoDelete: true);
try
{
    await channel.BasicPublishAsync(exchange, "no-binding", mandatory: true, basicProperties: new BasicProperties(), body: new byte[] { 1 });
    Console.WriteLine("FAIL  unroutable mandatory publish completed without an exception");
    return 1;
}
catch (PublishException ex) when (ex.IsReturn)
{
    Console.WriteLine("PASS  unroutable mandatory publish raised PublishException with IsReturn=true");
    return 0;
}
