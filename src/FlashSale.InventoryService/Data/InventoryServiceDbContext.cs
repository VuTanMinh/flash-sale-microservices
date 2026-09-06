using Microsoft.EntityFrameworkCore;
using Volo.Abp.EntityFrameworkCore;

namespace FlashSale.InventoryService.Data;

// No ABP module .Configure*() calls here (ConfigurePermissionManagement,
// ConfigureIdentity, etc.) -- this service doesn't depend on any of those
// modules. See InventoryServiceModule's [DependsOn] comment for why.
public class InventoryServiceDbContext : AbpDbContext<InventoryServiceDbContext>
{
    public InventoryServiceDbContext(DbContextOptions<InventoryServiceDbContext> options)
        : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder builder)
    {
        base.OnModelCreating(builder);

        /* Configure your own entities here */
    }
}
