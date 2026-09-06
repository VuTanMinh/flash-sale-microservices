namespace FlashSale.InventoryService.Inventory;

/// <summary>Bound from the "Redis" appsettings.json section.</summary>
public class RedisOptions
{
    public string Configuration { get; set; } = "localhost:6379";
}
