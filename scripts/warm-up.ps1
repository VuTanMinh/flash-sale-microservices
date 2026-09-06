# ============================================================
# Inventory warm-up (Week 7) -- loads initial stock into Redis before a
# Flash-sale "opens". Product availability is conditional on this having
# run: reserve.lua's GET on an unset inventory key returns nil, which the
# script treats as REJECTED (out of stock), not an error -- so a product
# that was never warmed up simply can't be reserved, by design, not by
# accident.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\warm-up.ps1
#
# Idempotent: safe to run twice in a row -- SET always sets the stock to the
# exact value given here, and the processed-order set is cleared, so a
# repeat run reproduces the same starting state.
# ============================================================

$ErrorActionPreference = "Stop"
$container = "infra-redis-1"

# product_id -> initial stock. flash-product-1 matches the product used
# throughout the JMeter smoke test (Week 3) and the C1 baseline comparison,
# so the same product id means the same thing everywhere in this project.
$products = @{
    "flash-product-1" = 1000
    "c0-demo-product"  = 1
    "c1-demo-product"  = 1
}

foreach ($productId in $products.Keys) {
    $stock = $products[$productId]
    $inventoryKey = "inventory:$productId"
    $processedKey = "processed:$productId"

    docker exec $container redis-cli SET $inventoryKey $stock | Out-Null
    docker exec $container redis-cli DEL $processedKey | Out-Null

    Write-Host "Warmed up '$productId': stock=$stock" -ForegroundColor Green
}

Write-Host "`nCurrent Redis inventory:" -ForegroundColor Cyan
foreach ($productId in $products.Keys) {
    $stock = docker exec $container redis-cli GET "inventory:$productId"
    Write-Host "  $productId -> $stock"
}
