using Microsoft.EntityFrameworkCore;
using FlashSale.InventoryService.Entities;
using Volo.Abp.EntityFrameworkCore;

namespace FlashSale.InventoryService.Data;

// No ABP module .Configure*() calls here (ConfigurePermissionManagement,
// ConfigureIdentity, etc.) -- this service doesn't depend on any of those
// modules. See InventoryServiceModule's [DependsOn] comment for why.
public class InventoryServiceDbContext : AbpDbContext<InventoryServiceDbContext>
{
    public DbSet<OutboxEvent> OutboxEvents => Set<OutboxEvent>();

    public DbSet<ProcessedMessage> ProcessedMessages => Set<ProcessedMessage>();

    public InventoryServiceDbContext(DbContextOptions<InventoryServiceDbContext> options)
        : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder builder)
    {
        base.OnModelCreating(builder);

        /* Configure your own entities here */

        builder.Entity<OutboxEvent>(b =>
        {
            b.ToTable("outbox_events", "inventory_service");
            b.HasKey(x => x.Id);
            // Unique on OrderId, not just Id -- this is what makes "ensure an
            // outbox row exists for this order" idempotent. See the class's
            // own doc comment for why that matters here.
            b.HasIndex(x => x.OrderId).IsUnique();
            b.Property(x => x.EventType).IsRequired();
            b.Property(x => x.Payload).IsRequired().HasColumnType("jsonb");
            b.HasIndex(x => x.Published);
        });

        builder.Entity<ProcessedMessage>(b =>
        {
            b.ToTable("processed_messages", "inventory_service");
            b.HasKey(x => x.Id);
            b.HasIndex(x => x.MessageId).IsUnique();
            b.Property(x => x.MessageType).IsRequired();
        });
    }
}
