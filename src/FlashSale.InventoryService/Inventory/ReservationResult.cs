namespace FlashSale.InventoryService.Inventory;

/// <summary>The three outcomes scripts/redis/reserve.lua can return (Step 7.2,
/// manually verified against redis-cli before any C# integration existed).</summary>
public enum ReservationResult
{
    Reserved,
    Duplicate,
    Rejected,

    /// <summary>The product's sale is not open: warm-up has not completed and been confirmed (docs/inventory.md).</summary>
    NotOpen,
}
