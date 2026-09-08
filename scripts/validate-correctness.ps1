# ============================================================
# Automated correctness validation (Week 8, checklist Step 8.3).
#
# Turns the Week 1 invariant list (docs/inventory-invariants.md) into an
# actual runnable check against a live system. This exact script is reused,
# UNMODIFIED, in Week 14 against real experimental data -- so it takes
# product id and expected initial stock as parameters rather than hardcoding
# them (Step 8.3's own explicit warning), since Week 13/14 run this against
# several different product/stock configurations.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\validate-correctness.ps1 `
#     -ProductId flash-product-1 -InitialStock 1000
#
# Exit code 0 if every checkable invariant holds, 1 if any FAILS. A PENDING
# result (Invariant 4, until Week 9's Inbox tables exist) does not fail the
# script -- it is not evidence of a violation, only evidence the check
# cannot run yet.
# ============================================================

param(
    [Parameter(Mandatory = $true)][string]$ProductId,
    [Parameter(Mandatory = $true)][int]$InitialStock
)

$ErrorActionPreference = "Stop"
$pgContainer = "infra-postgres-1"
$redisContainer = "infra-redis-1"
$db = "flashsale"
$pgUser = "flashsale"

$results = @()
function Add-Result($invariant, $status, $detail) {
    $script:results += [PSCustomObject]@{ Invariant = $invariant; Status = $status; Detail = $detail }
}

function Invoke-Psql($sql) {
    # Piped via stdin, not passed as a -c command-line argument: PowerShell
    # mangles embedded double quotes (needed here for Postgres's
    # case-sensitive "PascalCase" column names) when they cross the
    # native-command argument boundary. Piping sidesteps that entirely --
    # the same fix already proven in reset-and-seed.ps1.
    $sql | docker exec -i $pgContainer psql -U $pgUser -d $db -t -A
}

function Invoke-Redis($redisArgs) {
    docker exec $redisContainer redis-cli @redisArgs
}

Write-Host "Validating correctness for product '$ProductId' (seeded initial stock: $InitialStock)`n" -ForegroundColor Cyan

# --- Invariant 1: available_inventory >= 0 -----------------------------
$stockRaw = Invoke-Redis @("GET", "inventory:$ProductId")
if ([string]::IsNullOrWhiteSpace($stockRaw) -or $stockRaw -eq "(nil)") {
    Add-Result "1. available_inventory >= 0" "SETUP ERROR" `
        "inventory:$ProductId is unset in Redis -- was scripts/warm-up.ps1 (or an equivalent seed) run for this product?"
}
else {
    $stock = [int]$stockRaw
    if ($stock -ge 0) {
        Add-Result "1. available_inventory >= 0" "PASS" "Current stock: $stock"
    }
    else {
        Add-Result "1. available_inventory >= 0" "FAIL" "Current stock: $stock (negative -- over-sold)"
    }
}

# --- Invariant 2: successful_reservations <= initial_inventory ---------
$successCountSql = @"
SELECT COUNT(*) FROM order_service.orders
WHERE "ProductId" = '$ProductId' AND "State" IN ('Confirmed', 'Processing', 'Completed');
"@
$successCount = [int](Invoke-Psql $successCountSql).Trim()
if ($successCount -le $InitialStock) {
    Add-Result "2. successful_reservations <= initial_inventory" "PASS" `
        "$successCount successful reservation(s) <= $InitialStock seeded"
}
else {
    Add-Result "2. successful_reservations <= initial_inventory" "FAIL" `
        "$successCount successful reservation(s) EXCEEDS $InitialStock seeded -- over-sold"
}

# --- Invariant 3: at most one successful reservation per order ---------
# docs/inventory-invariants.md already resolved this as "not applicable by
# construction" once the ERD existed (Week 2): order_id is the orders
# table's own primary key, so a duplicate reservation for one order cannot
# appear as a duplicate row -- it would show up as a state anomaly instead,
# which invariant 2 above already would have caught as an over-sell. This
# still runs the query rather than skipping the check outright, so a
# regression in that structural guarantee (e.g. a future migration that
# drops the PK) would actually be caught, not just assumed away.
$duplicateIdSql = @"
SELECT COUNT(*) FROM (
  SELECT "Id" FROM order_service.orders GROUP BY "Id" HAVING COUNT(*) > 1
) dup;
"@
$duplicateIdCount = [int](Invoke-Psql $duplicateIdSql).Trim()
if ($duplicateIdCount -eq 0) {
    Add-Result "3. <=1 successful reservation per order" "PASS" `
        "No duplicate order ids found (structurally guaranteed by the primary key; verified, not just assumed)"
}
else {
    Add-Result "3. <=1 successful reservation per order" "FAIL" `
        "$duplicateIdCount duplicate order id(s) -- should be structurally impossible; investigate the schema"
}

# --- Invariant 4: duplicate message delivery never produces a second ---
# --- stock deduction ----------------------------------------------------
# Needs the Week 9 Inbox/processed_messages tables, which don't exist yet.
# Reported as PENDING, not PASS or FAIL -- a script that silently reported
# PASS here would be claiming a check it never actually ran.
$processedMessagesTableSql = @"
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = 'order_service' AND table_name = 'processed_messages';
"@
$tableExists = [int](Invoke-Psql $processedMessagesTableSql).Trim()
if ($tableExists -eq 0) {
    Add-Result "4. duplicate delivery never double-deducts stock" "PENDING" `
        "order_service.processed_messages does not exist yet (Week 9 Inbox pattern) -- not checkable until then"
}
else {
    $duplicateMessageSql = @"
SELECT COUNT(*) FROM (
  SELECT "MessageId" FROM order_service.processed_messages GROUP BY "MessageId" HAVING COUNT(*) > 1
) dup;
"@
    $duplicateMessageCount = [int](Invoke-Psql $duplicateMessageSql).Trim()
    if ($duplicateMessageCount -eq 0) {
        Add-Result "4. duplicate delivery never double-deducts stock" "PASS" "No duplicate message ids in processed_messages"
    }
    else {
        Add-Result "4. duplicate delivery never double-deducts stock" "FAIL" `
            "$duplicateMessageCount duplicate message id(s) processed more than once"
    }
}

# --- Bonus cross-check (not one of the four, but cheap extra confidence) ---
$processedSetSize = Invoke-Redis @("SCARD", "processed:$ProductId")
Write-Host "Cross-check (informational): Redis processed:$ProductId set size = $processedSetSize, Postgres successful reservations = $successCount" -ForegroundColor DarkGray
Write-Host ""

# --- Report ---------------------------------------------------------------
$results | Format-Table -AutoSize -Wrap

$failures = $results | Where-Object { $_.Status -eq "FAIL" }
$setupErrors = $results | Where-Object { $_.Status -eq "SETUP ERROR" }

if ($failures -or $setupErrors) {
    Write-Host "RESULT: FAILED" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "RESULT: All checkable invariants hold." -ForegroundColor Green
    exit 0
}
