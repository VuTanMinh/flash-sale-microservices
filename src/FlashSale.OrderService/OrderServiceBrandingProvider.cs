using Microsoft.Extensions.Localization;
using FlashSale.OrderService.Localization;
using Volo.Abp.DependencyInjection;
using Volo.Abp.Ui.Branding;

namespace FlashSale.OrderService;

[Dependency(ReplaceServices = true)]
public class OrderServiceBrandingProvider : DefaultBrandingProvider
{
    private IStringLocalizer<OrderServiceResource> _localizer;

    public OrderServiceBrandingProvider(IStringLocalizer<OrderServiceResource> localizer)
    {
        _localizer = localizer;
    }

    public override string AppName => _localizer["AppName"];
}
