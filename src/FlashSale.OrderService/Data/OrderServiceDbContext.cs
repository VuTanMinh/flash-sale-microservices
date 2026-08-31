using Microsoft.EntityFrameworkCore;
using FlashSale.OrderService.Entities;
using Volo.Abp.AuditLogging.EntityFrameworkCore;
using Volo.Abp.EntityFrameworkCore;
using Volo.Abp.FeatureManagement.EntityFrameworkCore;
using Volo.Abp.Identity.EntityFrameworkCore;
using Volo.Abp.OpenIddict.EntityFrameworkCore;
using Volo.Abp.PermissionManagement.EntityFrameworkCore;
using Volo.Abp.SettingManagement.EntityFrameworkCore;
using Volo.Abp.TenantManagement.EntityFrameworkCore;

namespace FlashSale.OrderService.Data;

public class OrderServiceDbContext : AbpDbContext<OrderServiceDbContext>
{
    public DbSet<Order> Orders => Set<Order>();

    public DbSet<OutboxEvent> OutboxEvents => Set<OutboxEvent>();

    public OrderServiceDbContext(DbContextOptions<OrderServiceDbContext> options)
        : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder builder)
    {
        base.OnModelCreating(builder);

        // docs/erd.md commits to schema-per-service for OUR OWN tables (orders,
        // outbox_events, processed_messages) — not for ABP's built-in module
        // tables (AbpUsers, AbpSettings, etc.), which stay in the EF/Npgsql
        // default "public" schema. HasDefaultSchema("order_service") here would
        // force every ABP module table into that schema too, and several modules
        // (setting management's runtime queries, at least) don't resolve a
        // non-default schema consistently outside of migration DDL generation —
        // confirmed by hitting "relation does not exist" at runtime despite the
        // table existing exactly where the migration put it. Simpler and just as
        // correct: leave the default alone, and schema-qualify our own entities
        // individually via .ToTable(name, "order_service") when they're added
        // (Week 5+), per docs/erd.md.

        /* Include modules to your migration db context */

        builder.ConfigurePermissionManagement();
        builder.ConfigureSettingManagement();
        builder.ConfigureAuditLogging();
        builder.ConfigureIdentity();
        builder.ConfigureOpenIddict();
        builder.ConfigureFeatureManagement();
        builder.ConfigureTenantManagement();

        /* Configure your own entities here */

        builder.Entity<Order>(b =>
        {
            b.ToTable("orders", "order_service");
            b.HasKey(x => x.Id);
            b.HasIndex(x => x.IdempotencyKey).IsUnique();
            b.Property(x => x.IdempotencyKey).IsRequired();
            b.Property(x => x.ProductId).IsRequired();
            b.Property(x => x.State).HasConversion<string>().IsRequired();
        });

        builder.Entity<OutboxEvent>(b =>
        {
            b.ToTable("outbox_events", "order_service");
            b.HasKey(x => x.Id);
            b.Property(x => x.EventType).IsRequired();
            b.Property(x => x.Payload).IsRequired().HasColumnType("jsonb");
            // The publisher polls WHERE Published = false on every tick (Week 6.2) --
            // without this index that becomes a full table scan as the table grows.
            b.HasIndex(x => x.Published);
        });
    }
}
