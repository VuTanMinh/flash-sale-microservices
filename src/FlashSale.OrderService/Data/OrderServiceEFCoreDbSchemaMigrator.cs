using Microsoft.EntityFrameworkCore;
using Volo.Abp.DependencyInjection;

namespace FlashSale.OrderService.Data;

public class OrderServiceEFCoreDbSchemaMigrator : ITransientDependency
{
    private readonly IServiceProvider _serviceProvider;

    public OrderServiceEFCoreDbSchemaMigrator(
        IServiceProvider serviceProvider)
    {
        _serviceProvider = serviceProvider;
    }

    public async Task MigrateAsync()
    {
        /* We intentionally resolve the OrderServiceDbContext
         * from IServiceProvider (instead of directly injecting it)
         * to properly get the connection string of the current tenant in the
         * current scope.
         */

        await _serviceProvider
            .GetRequiredService<OrderServiceDbContext>()
            .Database
            .MigrateAsync();
    }
}
