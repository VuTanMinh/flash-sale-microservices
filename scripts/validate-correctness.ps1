# ============================================================
# Correctness validator: the four inventory invariants, per configuration.
# Rules: docs/inventory-invariants.md, docs/validation.md.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\validate-correctness.ps1 -Config C2 -ProductId flash-product-1 -InitialStock 1000
#   powershell -ExecutionPolicy Bypass -File .\scripts\validate-correctness.ps1 -Config C1 -ProductId c1-demo-product -InitialStock 100
#
# Statuses: PASS, FAIL, INCONCLUSIVE (run not settled / data missing),
# NOT APPLICABLE (with the reason; only C1 invariant 4, which has no
# messaging), SETUP ERROR (database/Redis unreachable or a query failed).
# Exit 0 only if every invariant is PASS or NOT APPLICABLE. An empty result,
# a missing key or a failed query is never reported as PASS.
# ============================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet("C1", "C2")][string]$Config,
    [Parameter(Mandatory = $true)][string]$ProductId,
    [Parameter(Mandatory = $true)][int]$InitialStock,
    [string]$PgContainer = "infra-postgres-1",
    [string]$RedisContainer = "infra-redis-1"
)
# Continue: native stderr must not become a terminating error (PS 5.1); every
# call is checked explicitly instead.
$ErrorActionPreference = "Continue"
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$invariant, [string]$status, [string]$detail) {
    $results.Add([pscustomobject]@{ Invariant = $invariant; Status = $status; Detail = $detail })
}
if ($ProductId -notmatch '^[A-Za-z0-9_-]+$') { Write-Host "Invalid -ProductId" -ForegroundColor Red; exit 2 }

function Sql([string]$sql) {
    $out = $sql | docker exec -i $PgContainer psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL query failed: $(($out | Out-String).Trim())" }
    return @($out | Where-Object { $_ -ne "" })
}
function Redis([string[]]$a) {
    $out = docker exec $RedisContainer redis-cli @a 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Redis command failed: $(($out | Out-String).Trim())" }
    return @($out | Where-Object { $_ -ne "" })
}
# @() first: a one-row result comes back from a function as a plain string, and
# indexing a string returns a CHARACTER ('2'[0] -> [int] 50), not the value.
function Int1($rows) { $v = @($rows); if ($v.Count -ne 1 -or "$($v[0])" -notmatch '^-?\d+$') { throw "expected one integer, got '$($v -join ',')'" }; return [int]"$($v[0])" }

Write-Host "Validating $Config for product '$ProductId' (initial stock $InitialStock)`n" -ForegroundColor Cyan
try {
    if ($Config -eq "C1") {
        # C1: synchronous conditional UPDATE on order_service.inventory; each
        # request logs one decision row in baseline_orders.
        $stockRows = Sql "SELECT stock FROM order_service.inventory WHERE product_id = '$ProductId';"
        if (@($stockRows).Count -eq 0) { throw "order_service.inventory has no row for '$ProductId' (was reset-and-seed run?)" }
        $stock = Int1 $stockRows
        $confirmed = Int1 (Sql "SELECT count(*) FROM order_service.baseline_orders WHERE config = 'C1' AND product_id = '$ProductId' AND result = 'Confirmed';")
        $decisions = Int1 (Sql "SELECT count(*) FROM order_service.baseline_orders WHERE config = 'C1' AND product_id = '$ProductId';")
        if ($decisions -eq 0) { Add-Result "0. run has data" "INCONCLUSIVE" "no C1 decisions recorded for '$ProductId'" }

        if ($stock -ge 0) { Add-Result "1. available_inventory >= 0" "PASS" "stock $stock" } else { Add-Result "1. available_inventory >= 0" "FAIL" "stock $stock (oversold)" }
        if ($confirmed -le $InitialStock) { Add-Result "2. successful_reservations <= initial" "PASS" "$confirmed <= $InitialStock" } else { Add-Result "2. successful_reservations <= initial" "FAIL" "$confirmed Confirmed > $InitialStock initial" }
        # Each unit taken corresponds to exactly one Confirmed decision (one
        # reservation per request; no unlogged or double deduction).
        if ($InitialStock - $stock -eq $confirmed) { Add-Result "3. one reservation per order" "PASS" "units taken $($InitialStock - $stock) = Confirmed decisions $confirmed" }
        else { Add-Result "3. one reservation per order" "FAIL" "units taken $($InitialStock - $stock) <> Confirmed decisions $confirmed" }
        Add-Result "4. duplicate message never double-deducts" "NOT APPLICABLE" "C1 is synchronous: no broker messages exist to be duplicated"
    }
    else {
        # C2: Redis is the stock decision (inventory + processed set);
        # order_service.orders is the order outcome.
        $inv = Redis @("GET", "inventory:$ProductId")
        $inv = @($inv)
        if ($inv.Count -eq 0 -or "$($inv[0])" -notmatch '^-?\d+$') { throw "inventory:$ProductId is not set in Redis (was warm-up run?)" }
        $stock = [int]"$($inv[0])"
        $reserved = @(Redis @("SMEMBERS", "processed:$ProductId"))
        $reservedCount = Int1 (Redis @("SCARD", "processed:$ProductId"))
        $success = @(Sql "SELECT `"Id`" FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"State`" IN ('Confirmed','Processing','Completed');")
        $pending = Int1 (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"State`" = 'PendingStock';")
        $total = Int1 (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$ProductId';")
        if ($total -eq 0) { Add-Result "0. run has data" "INCONCLUSIVE" "no orders for '$ProductId'" }

        if ($stock -ge 0) { Add-Result "1. available_inventory >= 0" "PASS" "stock $stock" } else { Add-Result "1. available_inventory >= 0" "FAIL" "stock $stock (oversold)" }
        if ($reservedCount -le $InitialStock -and $success.Count -le $InitialStock) { Add-Result "2. successful_reservations <= initial" "PASS" "Redis reservations $reservedCount, successful orders $($success.Count), initial $InitialStock" }
        else { Add-Result "2. successful_reservations <= initial" "FAIL" "Redis reservations $reservedCount / successful orders $($success.Count) > $InitialStock" }

        # 3: the reservation set and the successful orders are the same set of
        # order ids -- one reservation per order, none missing, none extra.
        $reservedSet = @{}; foreach ($r in $reserved) { $reservedSet["$r"] = $true }
        $successSet = @{}; foreach ($s in $success) { $successSet["$s"] = $true }
        $notReserved = @($success | Where-Object { -not $reservedSet.ContainsKey("$_") })
        $notSuccessful = @($reserved | Where-Object { -not $successSet.ContainsKey("$_") })
        if ($pending -gt 0 -and $notSuccessful.Count -gt 0) {
            Add-Result "3. one reservation per order" "INCONCLUSIVE" "$pending order(s) still PendingStock; run not settled ($($notSuccessful.Count) reservation(s) without a final order state yet)"
        } elseif ($notReserved.Count -eq 0 -and $notSuccessful.Count -eq 0) {
            Add-Result "3. one reservation per order" "PASS" "Redis reservations and successful orders are the same $reservedCount order ids"
        } else {
            Add-Result "3. one reservation per order" "FAIL" "$($notReserved.Count) successful order(s) without a Redis reservation; $($notSuccessful.Count) reservation(s) whose order is not successful"
        }

        # 4: no double deduction -- units taken equal distinct reserved orders,
        # and the Inbox uniqueness that absorbs redelivery is actually in place.
        $taken = $InitialStock - $stock
        $inboxUnique = Int1 (Sql "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey) WHERE i.indisunique AND c.relname = 'processed_messages' AND a.attname = 'MessageId' AND n.nspname IN ('order_service','inventory_service');")
        if ($taken -eq $reservedCount -and $inboxUnique -eq 2) { Add-Result "4. duplicate message never double-deducts" "PASS" "units taken $taken = distinct reserved orders $reservedCount; Inbox MessageId unique in both services" }
        elseif ($taken -ne $reservedCount) { Add-Result "4. duplicate message never double-deducts" "FAIL" "units taken $taken <> distinct reserved orders $reservedCount (double or unrecorded deduction)" }
        else { Add-Result "4. duplicate message never double-deducts" "FAIL" "Inbox MessageId uniqueness missing ($inboxUnique of 2 services)" }
    }
}
catch {
    Add-Result "setup" "SETUP ERROR" $_.Exception.Message
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$bad = @($results | Where-Object { $_.Status -notin "PASS", "NOT APPLICABLE" })
if ($bad.Count -gt 0) { Write-Host "RESULT: FAILED ($($bad.Count) not passing)" -ForegroundColor Red; exit 1 }
Write-Host "RESULT: all four invariants hold for $Config." -ForegroundColor Green
exit 0
