using Microsoft.Extensions.Localization;
using FlashSale.InventoryService.Localization;
using Volo.Abp.DependencyInjection;
using Volo.Abp.Ui.Branding;

namespace FlashSale.InventoryService;

[Dependency(ReplaceServices = true)]
public class InventoryServiceBrandingProvider : DefaultBrandingProvider
{
    private IStringLocalizer<InventoryServiceResource> _localizer;

    public InventoryServiceBrandingProvider(IStringLocalizer<InventoryServiceResource> localizer)
    {
        _localizer = localizer;
    }

    public override string AppName => _localizer["AppName"];
}
