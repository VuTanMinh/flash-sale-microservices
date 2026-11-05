# ============================================================
# Correctness validator: the four inventory invariants plus accepted-order
# accounting (check 5), per configuration.
# Rules: docs/inventory-invariants.md, docs/validation.md.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\validate-correctness.ps1 -Config C2 -ProductId flash-product-1 -InitialStock 1000
#   powershell -ExecutionPolicy Bypass -File .\scripts\validate-correctness.ps1 -Config C1 -ProductId c1-demo-product -InitialStock 100
#   C3 (Week 12 box 2) and C4 (Week 13) run the same command as C2 with the same
#   evidence (service state + Redis) -- checks 0-5, no extra configuration.
#   -Products @{ 'p1' = n1; 'p2' = n2 } is an alternative to -ProductId/
#   -InitialStock: every product is checked with the same -Config and the script
#   exits non-zero if any product fails.
#   -RabbitMqContainer <rabbit> adds check 6 for C1 and C2: the C3 queue bound must
#   not be on the broker, or the run was not the configuration it claims to be.
#   -RunStartUtc <utc> adds check 0b (run isolation) per product: rows written
#   before the run started make the run INCONCLUSIVE.
#
# Statuses: PASS, FAIL, INCONCLUSIVE (run not settled / data missing),
# NOT APPLICABLE (with the reason; only C1 invariant 4, which has no
# messaging), SETUP ERROR (database/Redis unreachable or a query failed).
# Exit 0 only if every check is PASS or NOT APPLICABLE. An empty result,
# a missing key or a failed query is never reported as PASS.
# ============================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet("C1", "C2", "C3", "C4")][string]$Config,
    [string]$ProductId,
    [int]$InitialStock = -1,
    [hashtable]$Products = $null,
    [string]$PgContainer = "infra-postgres-1",
    [string]$RedisContainer = "infra-redis-1",
    [string]$RabbitMqContainer = "",
    [string]$RunStartUtc = ""
)
# Continue: native stderr must not become a terminating error (PS 5.1); every
# call is checked explicitly instead.
$ErrorActionPreference = "Continue"
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$invariant, [string]$status, [string]$detail) {
    $results.Add([pscustomobject]@{ Product = $ProductId; Invariant = $invariant; Status = $status; Detail = $detail })
}
# One product (-ProductId/-InitialStock) or many (-Products). -Products is the
# Week 13 experiment shape: every product is checked with the same -Config, and
# the script exits non-zero if any product fails.
$productsToCheck = New-Object System.Collections.Generic.List[object]
if ($Products -and $Products.Count -gt 0) {
    foreach ($p in @($Products.Keys | Sort-Object)) { $productsToCheck.Add([pscustomobject]@{ Id = [string]$p; Stock = [int]$Products[$p] }) }
} else {
    if ([string]::IsNullOrWhiteSpace($ProductId) -or $InitialStock -lt 0) { Write-Host "Either -Products or -ProductId/-InitialStock is required." -ForegroundColor Red; exit 2 }
    $productsToCheck.Add([pscustomobject]@{ Id = $ProductId; Stock = $InitialStock })
}
foreach ($prod in $productsToCheck) {
    if ("$($prod.Id)" -notmatch '^[A-Za-z0-9_-]+$') { Write-Host "Invalid product id '$($prod.Id)'" -ForegroundColor Red; exit 2 }
}

# Optional run filter (Week 14 P1): -RunStartUtc marks when this run started, so
# any row written before it is data from an earlier run and makes the run
# INCONCLUSIVE (check 0b). Parsed as UTC with AdjustToUniversal+AssumeUniversal
# (Part E pitfall: [DateTime]::Parse("...Z") alone returns local time).
$hasRunStart = -not [string]::IsNullOrWhiteSpace($RunStartUtc)
$runStart = [DateTime]::MinValue
if ($hasRunStart) {
    $ok = [DateTime]::TryParse($RunStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$runStart)
    if (-not $ok) {
        Write-Host "Invalid -RunStartUtc '$RunStartUtc': expected a UTC time such as 2026-11-05T03:28:50Z." -ForegroundColor Red
        exit 2
    }
    $runStartTs = $runStart.ToString("yyyy-MM-dd HH:mm:ss.fffffff")   # naive UTC, for `timestamp without time zone` columns
    $runStartTz = $runStart.ToString("o")                              # ISO 8601 with Z, for `timestamptz` columns
}

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

# Check 7 (Week 14 P1) SQL: one query returns up to 5 orders whose status
# history is missing or inconsistent, each row "OrderId:rule rule ...".
# __PID__ is replaced with the product id per iteration.
$historySqlTemplate = @'
WITH o AS (SELECT "Id", "State" FROM order_service.orders WHERE "ProductId" = '__PID__'),
h AS (SELECT "OrderId", "FromState", "ToState",
             row_number() OVER (PARTITION BY "OrderId" ORDER BY "Seq") AS rn,
             first_value("FromState") OVER (PARTITION BY "OrderId" ORDER BY "Seq") AS first_from,
             first_value("ToState") OVER (PARTITION BY "OrderId" ORDER BY "Seq") AS first_to,
             last_value("ToState") OVER (PARTITION BY "OrderId" ORDER BY "Seq" ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_to,
             lag("ToState") OVER (PARTITION BY "OrderId" ORDER BY "Seq") AS prev_to
      FROM order_service.order_status_history WHERE "OrderId" IN (SELECT "Id" FROM o)),
per_order AS (SELECT "OrderId", max(first_from) AS first_from, max(first_to) AS first_to, max(last_to) AS last_to,
             bool_or(rn > 1 AND "FromState" IS DISTINCT FROM prev_to) AS chain_broken
      FROM h GROUP BY "OrderId")
SELECT o."Id" || ':' || CASE WHEN p."OrderId" IS NULL THEN 'no-history'
       ELSE trim(CASE WHEN p.first_from IS NOT NULL OR p.first_to IS DISTINCT FROM 'PendingStock' THEN 'first-row ' ELSE '' END
           || CASE WHEN p.chain_broken THEN 'broken-chain ' ELSE '' END
           || CASE WHEN p.last_to IS DISTINCT FROM o."State" THEN 'last-state ' ELSE '' END) END
FROM o LEFT JOIN per_order p ON p."OrderId" = o."Id"
WHERE p."OrderId" IS NULL OR p.first_from IS NOT NULL OR p.first_to IS DISTINCT FROM 'PendingStock'
   OR p.chain_broken OR p.last_to IS DISTINCT FROM o."State"
ORDER BY o."Id" LIMIT 5;
'@

foreach ($prod in $productsToCheck) {
    $ProductId = [string]$prod.Id
    $InitialStock = [int]$prod.Stock
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
        if ($hasRunStart) {
            $before = Int1 (Sql "SELECT count(*) FROM order_service.baseline_orders WHERE config = 'C1' AND product_id = '$ProductId' AND created_at < '$runStartTz'::timestamptz;")
            if ($before -gt 0) { Add-Result "0b. run isolation" "INCONCLUSIVE" "$before row(s) are data from before this run" }
            else { Add-Result "0b. run isolation" "PASS" "no data before this run" }
        }

        if ($stock -ge 0) { Add-Result "1. available_inventory >= 0" "PASS" "stock $stock" } else { Add-Result "1. available_inventory >= 0" "FAIL" "stock $stock (oversold)" }
        if ($confirmed -le $InitialStock) { Add-Result "2. successful_reservations <= initial" "PASS" "$confirmed <= $InitialStock" } else { Add-Result "2. successful_reservations <= initial" "FAIL" "$confirmed Confirmed > $InitialStock initial" }
        # Each unit taken corresponds to exactly one Confirmed decision (one
        # reservation per request; no unlogged or double deduction).
        if ($InitialStock - $stock -eq $confirmed) { Add-Result "3. one reservation per order" "PASS" "units taken $($InitialStock - $stock) = Confirmed decisions $confirmed" }
        else { Add-Result "3. one reservation per order" "FAIL" "units taken $($InitialStock - $stock) <> Confirmed decisions $confirmed" }
        Add-Result "4. duplicate message never double-deducts" "NOT APPLICABLE" "C1 is synchronous: no broker messages exist to be duplicated"
    }
    else {
        # C2, C3 and C4: Redis is the stock decision (inventory + processed
        # set); order_service.orders is the order outcome. C3 and C4 use exactly
        # this C2 evidence -- no extra queries, no extra configuration.
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
        if ($hasRunStart) {
            $before = Int1 (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"RequestAcceptedAt`" < '$runStartTs'::timestamp;")
            if ($before -gt 0) { Add-Result "0b. run isolation" "INCONCLUSIVE" "$before row(s) are data from before this run" }
            else { Add-Result "0b. run isolation" "PASS" "no data before this run" }
        }

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

        # 5: accepted-order accounting (Week 12 box 2). Every order row for the
        # product is in exactly one of the terminal states (Completed, Rejected)
        # or the outstanding ones (PendingStock, Confirmed, Processing); their
        # counts must add up to the total, which equals "accepted" (a row only
        # exists for an accepted order). An outstanding order makes the check
        # INCONCLUSIVE (listed, not hidden); an order in an unexpected state is
        # a FAIL. A Rejected order that is also reserved, or a successful order
        # that is not reserved, is already check 3 -- not repeated here.
        $terminal = Int1 (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"State`" IN ('Completed','Rejected');")
        $outstanding = Int1 (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"State`" IN ('PendingStock','Confirmed','Processing');")
        $unexpected = Int1 (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"State`" NOT IN ('Completed','Rejected','PendingStock','Confirmed','Processing');")
        if ($unexpected -gt 0) {
            $badStates = @(Sql "SELECT `"Id`" || ':' || `"State`" FROM order_service.orders WHERE `"ProductId`" = '$ProductId' AND `"State`" NOT IN ('Completed','Rejected','PendingStock','Confirmed','Processing') ORDER BY `"RequestAcceptedAt`";") -join ", "
            Add-Result "5. accepted-order accounting" "FAIL" "$unexpected order(s) in an unexpected state: $badStates"
        } elseif ($outstanding -gt 0) {
            $outRows = @(Sql "SELECT o.`"Id`" || ' ' || o.`"State`" || ' age=' || round(extract(epoch from (now() - (o.`"RequestAcceptedAt`" at time zone 'UTC'))))::int || 's retries=' || GREATEST(0, count(oe.`"Id`") - 1) FROM order_service.orders o LEFT JOIN order_service.outbox_events oe ON oe.`"OrderId`" = o.`"Id`" AND oe.`"EventType`" = 'OrderPlaced' WHERE o.`"ProductId`" = '$ProductId' AND o.`"State`" IN ('PendingStock','Confirmed','Processing') GROUP BY o.`"Id`", o.`"State`", o.`"RequestAcceptedAt`" ORDER BY o.`"RequestAcceptedAt`";") -join "; "
            Add-Result "5. accepted-order accounting" "INCONCLUSIVE" "$outstanding outstanding order(s): $outRows"
        } else {
            Add-Result "5. accepted-order accounting" "PASS" "terminal $terminal + outstanding $outstanding = accepted $($terminal + $outstanding)"
        }

        # 7: status history complete (Week 14 P1). Every order's history, read by
        # Seq, must start with the creation row (FromState NULL -> PendingStock),
        # keep an unbroken FromState/ToState chain, and end at the order's State.
        $historyBad = @(Sql ($historySqlTemplate.Replace('__PID__', $ProductId)))
        if (@($historyBad).Count -eq 0) {
            Add-Result "7. status history complete" "PASS" "every order's history is a complete, unbroken chain ending at its state"
        } else {
            Add-Result "7. status history complete" "FAIL" "$(@($historyBad).Count) order(s) with bad history: $($historyBad -join '; ')"
        }
    }
    }
    catch {
        Add-Result "setup" "SETUP ERROR" $_.Exception.Message
    }
}

if ($RabbitMqContainer -and $Config -in "C1", "C2") {
    $ProductId = "(broker)"
    $bound = @(& (Join-Path $PSScriptRoot "set-queue-bounds.ps1") -Container $RabbitMqContainer -ExpectMaxLength 0)
    $boundExit = $LASTEXITCODE
    if ($boundExit -eq 0) { Add-Result "6. queue bound off" "PASS" "no C3 policy on the broker" }
    elseif ($boundExit -eq 1) { Add-Result "6. queue bound off" "FAIL" "$bound" }
    else { Add-Result "6. queue bound off" "SETUP ERROR" "$bound" }
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$bad = @($results | Where-Object { $_.Status -notin "PASS", "NOT APPLICABLE" })
if ($bad.Count -gt 0) { Write-Host "RESULT: FAILED ($($bad.Count) not passing)" -ForegroundColor Red; exit 1 }
Write-Host "RESULT: all checks hold for $Config ($($productsToCheck.Count) product(s))." -ForegroundColor Green
exit 0
