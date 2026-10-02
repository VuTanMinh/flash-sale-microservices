# ============================================================
# Week 8 TP-W02: proves scripts/validate-correctness.ps1 passes correct runs
# AND fails every kind of broken run -- no false green (docs/validation.md).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-validator.ps1 -Container verify-env-pg
#
# Builds small fixture datasets in a migrated throwaway database (one product
# id per case) and a throwaway Redis, runs the validator on each, and checks
# the overall verdict and the status of the invariant each case targets.
# ============================================================
param([Parameter(Mandatory = $true)][string]$Container)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$redis = "verify-val-redis"
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql) { $sql | docker exec -i $Container psql -U flashsale -d flashsale -q -v ON_ERROR_STOP=1 -f - *> $null }
function Redis([string[]]$a) { docker exec $redis redis-cli @a *> $null }
function Order([string]$product, [string]$id, [string]$state) {
    "INSERT INTO order_service.orders (`"Id`",`"IdempotencyKey`",`"ProductId`",`"Quantity`",`"State`",`"RequestAcceptedAt`",`"CorrelationId`") VALUES ('$id','$id','$product',1,'$state',now() at time zone 'utc','verify-validator');"
}
function Run([string]$config, [string]$product, [int]$initial) {
    $out = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config $config -ProductId $product -InitialStock $initial -PgContainer $Container -RedisContainer $redis *>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}
function Status([string]$text, [string]$invariantPrefix) {
    $line = ($text -split "`n" | Where-Object { $_ -match "^\s*$([regex]::Escape($invariantPrefix))" } | Select-Object -First 1)
    if (-not $line) { return "" }
    foreach ($s in "NOT APPLICABLE", "INCONCLUSIVE", "SETUP ERROR", "PASS", "FAIL") { if ($line -match [regex]::Escape($s)) { return $s } }
    return ""
}
function Expect([string]$name, $run, [int]$code, [hashtable]$statuses) {
    $ok = $run.Code -eq $code
    $detail = "exit $($run.Code)"
    foreach ($k in $statuses.Keys) { $got = Status $run.Text $k; if ($got -ne $statuses[$k]) { $ok = $false; $detail += "; '$k' = '$got' (expected $($statuses[$k]))" } }
    Check $name $ok $detail
}

try {
    docker rm -f $redis *> $null
    docker run -d --name $redis redis:7 | Out-Null
    Start-Sleep 3
    Sql "DELETE FROM order_service.orders WHERE `"CorrelationId`" = 'verify-validator'; DELETE FROM order_service.baseline_orders WHERE product_id LIKE 'val-%'; DELETE FROM order_service.inventory WHERE product_id LIKE 'val-%';"

    # ---------------- C1 ----------------
    function C1([string]$p, [int]$stock, [int]$confirmed, [int]$rejected) {
        $q = "INSERT INTO order_service.inventory VALUES ('$p', $stock);"
        for ($i = 0; $i -lt $confirmed; $i++) { $q += "INSERT INTO order_service.baseline_orders (config, product_id, result) VALUES ('C1','$p','Confirmed');" }
        for ($i = 0; $i -lt $rejected; $i++) { $q += "INSERT INTO order_service.baseline_orders (config, product_id, result) VALUES ('C1','$p','Rejected');" }
        Sql $q
    }
    C1 "val-c1-good" 2 3 4
    Expect "C1 correct run (5 units, 3 sold, 4 rejected) -> passes; invariant 4 NOT APPLICABLE" (Run C1 "val-c1-good" 5) 0 @{ "1." = "PASS"; "2." = "PASS"; "3." = "PASS"; "4." = "NOT APPLICABLE" }
    C1 "val-c1-oversold" -1 6 0
    Expect "C1 oversold (stock -1, 6 sold of 5) -> fails invariants 1 and 2" (Run C1 "val-c1-oversold" 5) 1 @{ "1." = "FAIL"; "2." = "FAIL" }
    C1 "val-c1-unlogged" 2 2 0
    Expect "C1 deduction without a Confirmed decision (3 taken, 2 logged) -> fails invariant 3" (Run C1 "val-c1-unlogged" 5) 1 @{ "1." = "PASS"; "2." = "PASS"; "3." = "FAIL" }
    Sql "INSERT INTO order_service.inventory VALUES ('val-c1-empty', 5);"
    Expect "C1 run with no decisions -> INCONCLUSIVE, never a pass" (Run C1 "val-c1-empty" 5) 1 @{ "0." = "INCONCLUSIVE" }
    Expect "C1 product missing -> SETUP ERROR, never a pass" (Run C1 "val-c1-missing" 5) 1 @{ "setup" = "SETUP ERROR" }

    # ---------------- C2 ----------------
    function C2([string]$p, [int]$stock, [string[]]$reserved, [hashtable]$orders) {
        Redis @("SET", "inventory:$p", "$stock")
        if ($reserved.Count -gt 0) { Redis (@("SADD", "processed:$p") + $reserved) }
        $q = ""; foreach ($id in $orders.Keys) { $q += Order $p $id $orders[$id] }
        if ($q) { Sql $q }
    }
    $g = @(1..3 | ForEach-Object { [guid]::NewGuid().ToString() })
    C2 "val-c2-good" 3 @($g[0], $g[1]) @{ $g[0] = "Confirmed"; $g[1] = "Completed"; $g[2] = "Rejected" }
    Expect "C2 correct run (5 units, 2 reserved/successful, 1 rejected) -> passes all four" (Run C2 "val-c2-good" 5) 0 @{ "1." = "PASS"; "2." = "PASS"; "3." = "PASS"; "4." = "PASS" }

    $o = @(1..6 | ForEach-Object { [guid]::NewGuid().ToString() }); $h = @{}; foreach ($x in $o) { $h[$x] = "Confirmed" }
    C2 "val-c2-oversold" -1 $o $h
    Expect "C2 oversold (stock -1, 6 reservations of 5) -> fails invariants 1 and 2" (Run C2 "val-c2-oversold" 5) 1 @{ "1." = "FAIL"; "2." = "FAIL" }

    $m = @(1..3 | ForEach-Object { [guid]::NewGuid().ToString() })
    C2 "val-c2-mismatch" 3 @($m[0], $m[1]) @{ $m[0] = "Confirmed"; $m[1] = "Rejected"; $m[2] = "Confirmed" }
    Expect "C2 reservation/order mismatch (a reserved order Rejected, a Confirmed order never reserved) -> fails invariant 3" (Run C2 "val-c2-mismatch" 5) 1 @{ "1." = "PASS"; "2." = "PASS"; "3." = "FAIL" }

    $d = @(1..2 | ForEach-Object { [guid]::NewGuid().ToString() })
    C2 "val-c2-double" 2 $d @{ $d[0] = "Confirmed"; $d[1] = "Confirmed" }
    Expect "C2 double deduction (3 units taken for 2 reserved orders) -> fails invariant 4" (Run C2 "val-c2-double" 5) 1 @{ "1." = "PASS"; "2." = "PASS"; "3." = "PASS"; "4." = "FAIL" }

    $u = [guid]::NewGuid().ToString()
    C2 "val-c2-unsettled" 4 @($u) @{ $u = "PendingStock" }
    Expect "C2 run not settled (reserved order still PendingStock) -> INCONCLUSIVE, never a pass" (Run C2 "val-c2-unsettled" 5) 1 @{ "3." = "INCONCLUSIVE" }

    Expect "C2 inventory key missing -> SETUP ERROR, never a pass" (Run C2 "val-c2-nokey" 5) 1 @{ "setup" = "SETUP ERROR" }
    $saved = $Container; $Container = "no-such-container"
    $r = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C1 -ProductId val-c1-good -InitialStock 5 -PgContainer "no-such-container" -RedisContainer $redis *>&1 | Out-String
    $Container = $saved
    Check "database unreachable -> SETUP ERROR and exit 1" ($LASTEXITCODE -eq 1 -and $r -match "SETUP ERROR")
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "DELETE FROM order_service.orders WHERE `"CorrelationId`" = 'verify-validator'; DELETE FROM order_service.baseline_orders WHERE product_id LIKE 'val-%'; DELETE FROM order_service.inventory WHERE product_id LIKE 'val-%';"
    docker rm -f $redis *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Validator passes correct runs and fails every broken one (no false green)." -ForegroundColor Green
