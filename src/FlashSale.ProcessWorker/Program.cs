using FlashSale.ProcessWorker.Messaging;
using Prometheus;
using Serilog;
using Serilog.Events;
using Serilog.Formatting.Compact;

namespace FlashSale.ProcessWorker;

public class Program
{
    public async static Task<int> Main(string[] args)
    {
        Log.Logger = new LoggerConfiguration()
#if DEBUG
            .MinimumLevel.Debug()
#else
            .MinimumLevel.Information()
#endif
            .MinimumLevel.Override("Microsoft", LogEventLevel.Information)
            .Enrich.FromLogContext()
            .Enrich.WithProperty("Service", "FlashSale.ProcessWorker")
            // JSON to the file sink, human-readable to the console: Step 11.3
            // wants logs queryable later, and Week 13/14 will be reading these
            // files with tooling rather than eyes. The console stays plain
            // text because that is what a developer actually watches during a
            // live test -- same split applied to all three services.
            .WriteTo.Async(c => c.File(new CompactJsonFormatter(), "Logs/logs.json"))
            .WriteTo.Async(c => c.Console())
            .CreateLogger();

        try
        {
            var builder = WebApplication.CreateBuilder(args);
            builder.Host.UseSerilog();

            // verify-worker.ps1 case E1 waits 30 s for the Worker to exit after
            // Ctrl+C, so the 30 s default HostOptions.ShutdownTimeout can race
            // that check. Pin it to 15 s; this only shortens the wait and does
            // not change the shutdown behaviour (in-flight orders still stay
            // unacked and return to the queue).
            builder.Services.Configure<HostOptions>(options => options.ShutdownTimeout = TimeSpan.FromSeconds(15));

            builder.Services.Configure<RabbitMqOptions>(builder.Configuration.GetSection("RabbitMQ"));
            builder.Services.Configure<ProcessingOptions>(builder.Configuration.GetSection("Processing"));
            builder.Services.AddSingleton<OrderProcessedPublisher>();
            builder.Services.AddSingleton<OrderProcessingStartedPublisher>();
            builder.Services.AddHostedService<StockReservedConsumer>();

            var app = builder.Build();

            // The only HTTP this service serves. Prometheus scrapes it
            // (Step 11.3); nothing else is exposed because nothing else needs
            // to be -- the Process Worker's whole interface is the broker.
            app.MapMetrics();

            Log.Information("Starting FlashSale.ProcessWorker.");
            await app.RunAsync();
            return 0;
        }
        catch (Exception ex)
        {
            if (ex is HostAbortedException)
            {
                throw;
            }

            Log.Fatal(ex, "FlashSale.ProcessWorker terminated unexpectedly!");
            return 1;
        }
        finally
        {
            Log.CloseAndFlush();
        }
    }
}
