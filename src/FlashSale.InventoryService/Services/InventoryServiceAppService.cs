using FlashSale.InventoryService.Localization;
using Volo.Abp.Application.Services;

namespace FlashSale.InventoryService.Services;

/* Inherit your application services from this class. */
public abstract class InventoryServiceAppService : ApplicationService
{
    protected InventoryServiceAppService()
    {
        LocalizationResource = typeof(InventoryServiceResource);
    }
}