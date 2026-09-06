using Microsoft.EntityFrameworkCore;
using Volo.Abp.DependencyInjection;

namespace FlashSale.InventoryService.Data;

public class InventoryServiceEFCoreDbSchemaMigrator : ITransientDependency
{
    private readonly IServiceProvider _serviceProvider;

    public InventoryServiceEFCoreDbSchemaMigrator(
        IServiceProvider serviceProvider)
    {
        _serviceProvider = serviceProvider;
    }

    public async Task MigrateAsync()
    {
        /* We intentionally resolve the InventoryServiceDbContext
         * from IServiceProvider (instead of directly injecting it)
         * to properly get the connection string of the current tenant in the
         * current scope.
         */

        await _serviceProvider
            .GetRequiredService<InventoryServiceDbContext>()
            .Database
            .MigrateAsync();
    }
}
