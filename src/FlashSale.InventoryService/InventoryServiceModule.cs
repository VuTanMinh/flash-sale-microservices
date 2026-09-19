using Microsoft.AspNetCore.Cors;
using Microsoft.OpenApi;
using Prometheus;
using FlashSale.InventoryService.Data;
using FlashSale.InventoryService.Inventory;
using FlashSale.InventoryService.Localization;
using FlashSale.InventoryService.Messaging;
using Microsoft.Extensions.Options;
using StackExchange.Redis;
using Volo.Abp;
using Volo.Abp.AspNetCore.Mvc;
using Volo.Abp.AspNetCore.Mvc.Localization;
using Volo.Abp.AspNetCore.Serilog;
using Volo.Abp.Autofac;
using Volo.Abp.EntityFrameworkCore;
using Volo.Abp.EntityFrameworkCore.PostgreSql;
using Volo.Abp.Localization;
using Volo.Abp.Localization.ExceptionHandling;
using Volo.Abp.Modularity;
using Volo.Abp.Swashbuckle;
using Volo.Abp.Validation.Localization;
using Volo.Abp.VirtualFileSystem;

namespace FlashSale.InventoryService;

// Deliberately much smaller [DependsOn] list than a stock `abp new` scaffold
// produces. Order Service (Week 3) was scaffolded with the full default set
// (Identity, Account, PermissionManagement, TenantManagement,
// FeatureManagement, SettingManagement, OpenIddict, AuditLogging,
// multi-tenancy, the LeptonX UI theme) and that turned out to be a real
// source of friction, not just unused weight: it's what caused the Week 3
// migration/schema bug (SettingManagement's runtime queries don't resolve a
// non-default schema consistently), and Week 4's API contract review found
// ~29 of ~30 exposed endpoints were this unused scaffolding, none of them
// traceable to any state-machine transition. docs/00-scope-lock.md already
// excludes user management, auth/authz, and multi-tenancy entirely -- this
// service is scaffolded to match that from the start, rather than carrying
// the same cleanup debt Order Service still has (that cleanup is still a
// flagged, not-yet-done item there, not retrofitted here after the fact).
[DependsOn(
    typeof(AbpAspNetCoreMvcModule),
    typeof(AbpAutofacModule),
    typeof(AbpEntityFrameworkCorePostgreSqlModule),
    typeof(AbpSwashbuckleModule),
    typeof(AbpAspNetCoreSerilogModule)
)]
public class InventoryServiceModule : AbpModule
{
    public override void PreConfigureServices(ServiceConfigurationContext context)
    {
        context.Services.PreConfigure<AbpMvcDataAnnotationsLocalizationOptions>(options =>
        {
            options.AddAssemblyResource(
                typeof(InventoryServiceResource)
            );
        });

        InventoryServiceGlobalFeatureConfigurator.Configure();
        InventoryServiceModuleExtensionConfigurator.Configure();
        InventoryServiceEfCoreEntityExtensionMappings.Configure();
    }

    public override void ConfigureServices(ServiceConfigurationContext context)
    {
        var hostingEnvironment = context.Services.GetHostingEnvironment();
        var configuration = context.Services.GetConfiguration();

        ConfigureSwagger(context.Services);
        ConfigureAutoApiControllers();
        ConfigureVirtualFiles(hostingEnvironment);
        ConfigureLocalization();
        ConfigureCors(context, configuration);
        ConfigureEfCore(context);
        ConfigureInventoryReservation(context, configuration);
    }

    private void ConfigureVirtualFiles(IWebHostEnvironment hostingEnvironment)
    {
        Configure<AbpVirtualFileSystemOptions>(options =>
        {
            options.FileSets.AddEmbedded<InventoryServiceModule>();
            if (hostingEnvironment.IsDevelopment())
            {
                /* Using physical files in development, so we don't need to recompile on changes */
                options.FileSets.ReplaceEmbeddedByPhysical<InventoryServiceModule>(hostingEnvironment.ContentRootPath);
            }
        });
    }

    private void ConfigureAutoApiControllers()
    {
        Configure<AbpAspNetCoreMvcOptions>(options =>
        {
            options.ConventionalControllers.Create(typeof(InventoryServiceModule).Assembly);
        });
    }

    // No OAuth wiring (AddAbpSwaggerGenWithOAuth) -- that requires OpenIddict,
    // which this service deliberately doesn't depend on.
    private void ConfigureSwagger(IServiceCollection services)
    {
        services.AddAbpSwaggerGen(
            options =>
            {
                options.SwaggerDoc("v1", new OpenApiInfo { Title = "InventoryService API", Version = "v1" });
                options.DocInclusionPredicate((docName, description) => true);
                options.CustomSchemaIds(type => type.FullName);
            });
    }

    private void ConfigureLocalization()
    {
        Configure<AbpLocalizationOptions>(options =>
        {
            options.Resources
                .Add<InventoryServiceResource>("en")
                .AddBaseTypes(typeof(AbpValidationResource))
                .AddVirtualJson("/Localization/InventoryService");

            options.DefaultResourceType = typeof(InventoryServiceResource);
            options.Languages.Add(new LanguageInfo("en", "en", "English"));
        });

        Configure<AbpExceptionLocalizationOptions>(options =>
        {
            options.MapCodeNamespace("InventoryService", typeof(InventoryServiceResource));
        });
    }

    private void ConfigureCors(ServiceConfigurationContext context, IConfiguration configuration)
    {
        context.Services.AddCors(options =>
        {
            options.AddDefaultPolicy(builder =>
            {
                builder
                    .WithOrigins(
                        configuration["App:CorsOrigins"]?
                            .Split(",", StringSplitOptions.RemoveEmptyEntries)
                            .Select(o => o.RemovePostFix("/"))
                            .ToArray() ?? Array.Empty<string>()
                    )
                    .WithAbpExposedHeaders()
                    .SetIsOriginAllowedToAllowWildcardSubdomains()
                    .AllowAnyHeader()
                    .AllowAnyMethod()
                    .AllowCredentials();
            });
        });
    }

    private void ConfigureEfCore(ServiceConfigurationContext context)
    {
        context.Services.AddAbpDbContext<InventoryServiceDbContext>(options =>
        {
            options.AddDefaultRepositories(includeAllEntities: true);
        });

        Configure<AbpDbContextOptions>(options =>
        {
            options.Configure(configurationContext =>
            {
                configurationContext.UseNpgsql();
            });
        });
    }

    // Registered explicitly rather than via ABP's conventional
    // ISingletonDependency/ITransientDependency marker interfaces -- Order
    // Service hit that convention silently not picking up a class in
    // practice (Week 6), so explicit registration is used consistently here
    // too: guaranteed to work, and visible in one place instead of implied.
    private void ConfigureInventoryReservation(ServiceConfigurationContext context, IConfiguration configuration)
    {
        context.Services.Configure<RabbitMqOptions>(configuration.GetSection("RabbitMQ"));
        context.Services.Configure<RedisOptions>(configuration.GetSection("Redis"));

        context.Services.AddSingleton<IConnectionMultiplexer>(sp =>
        {
            var redisOptions = sp.GetRequiredService<IOptions<RedisOptions>>().Value;
            return ConnectionMultiplexer.Connect(redisOptions.Configuration);
        });

        context.Services.AddTransient<InventoryReservationService>();
        context.Services.AddHostedService<OrderPlacedConsumer>();

        // Step 8.1 -- this service's own Outbox publisher, for
        // StockReserved/StockRejected. Same explicit-registration reasoning
        // as above.
        context.Services.AddSingleton<IOutboxMessagePublisher, RabbitMqOutboxPublisher>();
        context.Services.AddHostedService<OutboxPublisherWorker>();
    }

    public override void OnApplicationInitialization(ApplicationInitializationContext context)
    {
        var app = context.GetApplicationBuilder();
        var env = context.GetEnvironment();

        if (env.IsDevelopment())
        {
            app.UseDeveloperExceptionPage();
        }

        app.UseAbpRequestLocalization();

        app.UseCorrelationId();
        app.MapAbpStaticAssets();
        app.UseRouting();
        app.UseCors();

        app.UseUnitOfWork();
        app.UseAuthorization();

        app.UseSwagger();
        app.UseAbpSwaggerUI(options =>
        {
            options.SwaggerEndpoint("/swagger/v1/swagger.json", "InventoryService API");
        });

        app.UseAbpSerilogEnrichers();
        // Week 11, Step 11.3 -- /metrics for Prometheus to scrape
        // (infra/prometheus.yml lists this service as a target).
        app.UseConfiguredEndpoints(endpoints => endpoints.MapMetrics());
    }
}
