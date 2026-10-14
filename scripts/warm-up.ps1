# ============================================================
# Inventory warm-up (docs/inventory.md). Opens the sale for each product only
# after its stock is loaded AND confirmed.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\warm-up.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\warm-up.ps1 -Container verify-inv-redis -Force
#
# Per product, one atomic Lua EVAL: SET inventory:{id}, DEL processed:{id},
# SET sale:open:{id}. Then a read-back confirms stock, an empty processed set
# and the open marker; the script prints CONFIRMED per product and exits 1 if
# any product does not confirm.
# A product whose sale is already open is NOT reset (that would restore stock
# and forget reservations mid-sale) unless -Force is given -- meant for
# experiment resets only.
# ============================================================
param(
    [string]$Container = "infra-redis-1",
    [hashtable]$Products = @{
        # flash-product-1 is the JMeter/C1 product; the demo ids match C0/C1.
        "flash-product-1" = 1000
        "c0-demo-product"  = 1
        "c1-demo-product"  = 1
    },
    [switch]$Force
)
# Continue: docker/redis-cli stderr must not become a terminating error (PS 5.1).
$ErrorActionPreference = "Continue"
$failures = 0

$warmUp = @'
if ARGV[2] ~= '1' and redis.call('EXISTS', KEYS[3]) == 1 then
  return 'ALREADY_OPEN'
end
redis.call('SET', KEYS[1], ARGV[1])
redis.call('DEL', KEYS[2])
redis.call('SET', KEYS[3], '1')
return 'OK'
'@

foreach ($productId in ($Products.Keys | Sort-Object)) {
    $stock = [int]$Products[$productId]
    $inv = "inventory:$productId"; $processed = "processed:$productId"; $open = "sale:open:$productId"
    $forceArg = if ($Force) { "1" } else { "0" }
    $result = docker exec $Container redis-cli EVAL $warmUp 3 $inv $processed $open $stock $forceArg 2>&1 | Out-String
    $result = $result.Trim()
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL  $productId`: redis-cli failed: $result" -ForegroundColor Red; $failures++; continue }
    if ($result -eq "ALREADY_OPEN") {
        Write-Host "SKIP  $productId`: sale already open; not reset (use -Force for an experiment reset)" -ForegroundColor Yellow
        continue
    }

    # Confirmation: read everything back.
    $gotStock = (docker exec $Container redis-cli GET $inv 2>&1 | Out-String).Trim()
    $gotProcessed = (docker exec $Container redis-cli SCARD $processed 2>&1 | Out-String).Trim()
    $gotOpen = (docker exec $Container redis-cli EXISTS $open 2>&1 | Out-String).Trim()
    if ($gotStock -eq "$stock" -and $gotProcessed -eq "0" -and $gotOpen -eq "1") {
        Write-Host "CONFIRMED  $productId`: stock=$gotStock, reservations=0, sale open" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $productId`: read-back stock=$gotStock reservations=$gotProcessed open=$gotOpen (expected $stock/0/1)" -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) { Write-Host "$failures product(s) did not confirm; their sale must not be treated as open." -ForegroundColor Red; exit 1 }
Write-Host "Warm-up complete and confirmed." -ForegroundColor Green
