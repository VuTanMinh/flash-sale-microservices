using FlashSale.OrderService.Data;
using FlashSale.OrderService.Experiments.C0Naive;
using Serilog;
using Serilog.Events;
using Serilog.Formatting.Compact;
using Volo.Abp.Data;

namespace FlashSale.OrderService;

public class Program
{
    public async static Task<int> Main(string[] args)
    {
        // https://www.npgsql.org/efcore/release-notes/6.0.html#opting-out-of-the-new-timestamp-mapping-logic
        AppContext.SetSwitch("Npgsql.EnableLegacyTimestampBehavior", true);

        var loggerConfiguration = new LoggerConfiguration()
#if DEBUG
            .MinimumLevel.Debug()
#else
            .MinimumLevel.Information()
#endif
            .MinimumLevel.Override("Microsoft", LogEventLevel.Information)
            .MinimumLevel.Override("Microsoft.EntityFrameworkCore", LogEventLevel.Warning)
            .Enrich.FromLogContext()
            // Week 11, Step 11.3: the file sink is JSON (one object per line,
            // CompactJsonFormatter) rather than the plain text this used to
            // write. Structured output is what makes the correlation id added
            // in Step 11.2 actually *queryable* -- Week 13/14 need to filter
            // thousands of lines by CorrelationId and read timestamps back as
            // fields, not regex them out of a rendered string. The console
            // sink deliberately stays human-readable: it is watched live by a
            // person, not parsed.
            .WriteTo.Async(c => c.File(new CompactJsonFormatter(), "Logs/logs.json"))
            .WriteTo.Async(c => c.Console());

        if (IsMigrateDatabase(args))
        {
            loggerConfiguration.MinimumLevel.Override("Volo.Abp", LogEventLevel.Warning);
            loggerConfiguration.MinimumLevel.Override("Microsoft", LogEventLevel.Warning);
        }

        Log.Logger = loggerConfiguration.CreateLogger();

        if (IsRunC0Demo(args))
        {
            // Deliberately bypasses the whole ABP host (identity, permissions,
            // etc.) — this demo only needs a Postgres connection string, and
            // skipping the host keeps it maximally isolated from the real app.
            var demoConfiguration = new ConfigurationBuilder()
                .SetBasePath(Directory.GetCurrentDirectory())
                .AddJsonFile("appsettings.json", optional: false)
                .Build();
            await C0NaiveDemo.RunAsync(demoConfiguration.GetConnectionString("Default")!);
            return 0;
        }

        try
        {
            var builder = WebApplication.CreateBuilder(args);
            builder.Host.AddAppSettingsSecretsJson()
                .UseAutofac()
                .UseSerilog();
            if (IsMigrateDatabase(args))
            {
                builder.Services.AddDataMigrationEnvironment();
            }
            await builder.AddApplicationAsync<OrderServiceModule>();
            var app = builder.Build();
            await app.InitializeApplicationAsync();

            if (IsMigrateDatabase(args))
            {
                await app.Services.GetRequiredService<OrderServiceDbMigrationService>().MigrateAsync();
                return 0;
            }

            Log.Information("Starting FlashSale.OrderService.");
            await app.RunAsync();
            return 0;
        }
        catch (Exception ex)
        {
            if (ex is HostAbortedException)
            {
                throw;
            }

            Log.Fatal(ex, "FlashSale.OrderService terminated unexpectedly!");
            return 1;
        }
        finally
        {
            Log.CloseAndFlush();
        }
    }

    private static bool IsMigrateDatabase(string[] args)
    {
        return args.Any(x => x.Contains("--migrate-database", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsRunC0Demo(string[] args)
    {
        return args.Any(x => x.Contains("--run-c0-demo", StringComparison.OrdinalIgnoreCase));
    }
}
