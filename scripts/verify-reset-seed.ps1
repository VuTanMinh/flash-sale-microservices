# ============================================================
# Proves scripts/reset-and-seed.ps1 is repeatable and seeds exact values.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-reset-seed.ps1 -Container verify-env-pg
#
# 1. reset+seed, snapshot      2. dirty every table on purpose
# 3. reset+seed, snapshot      4. reset+seed again immediately, snapshot
# Each snapshot must equal the EXPECTED values below (kept in sync with the
# table in docs/baseline-c0-c1.md, stated independently of seed.sql), and
# all three must be byte-identical. Exits 1 on any mismatch.
# Without -Container it targets the Compose "postgres" service -- that resets
# the real local baseline tables, so prefer a throwaway container.
# ============================================================
param([string]$Container)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$composeFile = Join-Path $repoRoot "infra\docker-compose.yml"
$failures = 0

# Expected starting state (docs/baseline-c0-c1.md, "Reset and seed").
$expected = @(
    "inventory|c0-demo-product|1",
    "inventory|c1-demo-product|1",
    "inventory|flash-product-1|1000",
    "baseline_orders|rows|0",
    "owner|baseline_orders|order_service_user",
    "owner|inventory|order_service_user"
) -join "`n"

function Psql([string]$sql) {
    if ($Container) { $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - }
    else { $out = $sql | docker compose -f $composeFile exec -T postgres psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - }
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $sql" }
    return (@($out | Where-Object { $_ -ne "" }) -join "`n")
}

function Snapshot {
    return Psql @"
SELECT 'inventory|' || product_id || '|' || stock FROM order_service.inventory ORDER BY product_id;
SELECT 'baseline_orders|rows|' || count(*) FROM order_service.baseline_orders;
SELECT 'owner|' || c.relname || '|' || pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'order_service' AND c.relname IN ('inventory', 'baseline_orders') ORDER BY c.relname;
"@
}

function ResetSeed([int]$n) {
    $psArgs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $repoRoot "scripts\reset-and-seed.ps1"))
    if ($Container) { $psArgs += @("-Container", $Container) }
    powershell @psArgs *> (Join-Path $env:TEMP "reset-seed-run$n.log")
    if ($LASTEXITCODE -eq 0) { Write-Host "PASS  reset-and-seed run $n exited 0" -ForegroundColor Green }
    else { Write-Host "FAIL  reset-and-seed run $n exited $LASTEXITCODE" -ForegroundColor Red; $script:failures++ }
}

function Check([string]$name, [string]$actual) {
    if ($actual -ceq $expected) { Write-Host "PASS  $name matches the expected starting state" -ForegroundColor Green }
    else {
        Write-Host "FAIL  $name" -ForegroundColor Red
        Write-Host "      expected:`n$($expected -replace '(?m)^', '        ')"
        Write-Host "      actual:`n$($actual -replace '(?m)^', '        ')"
        $script:failures++
    }
}

ResetSeed 1
$s1 = Snapshot
Check "snapshot after run 1" $s1

Write-Host "Dirtying every baseline table on purpose..." -ForegroundColor Cyan
Psql @"
UPDATE order_service.inventory SET stock = -7 WHERE product_id = 'c0-demo-product';
UPDATE order_service.inventory SET stock = 3 WHERE product_id = 'flash-product-1';
DELETE FROM order_service.inventory WHERE product_id = 'c1-demo-product';
INSERT INTO order_service.inventory (product_id, stock) VALUES ('leftover-product', 42);
INSERT INTO order_service.baseline_orders (config, product_id, result)
  SELECT 'C1', 'flash-product-1', 'Confirmed' FROM generate_series(1, 25);
"@ | Out-Null
$dirty = Snapshot
if ($dirty -ne $expected) { Write-Host "PASS  dirty state differs from expected (the test can fail)" -ForegroundColor Green }
else { Write-Host "FAIL  dirtying did not change anything" -ForegroundColor Red; $failures++ }

ResetSeed 2
$s2 = Snapshot
Check "snapshot after run 2 (from dirty state)" $s2

ResetSeed 3
$s3 = Snapshot
Check "snapshot after run 3 (back-to-back)" $s3

if ($s1 -ceq $s2 -and $s2 -ceq $s3) { Write-Host "PASS  all three snapshots identical" -ForegroundColor Green }
else { Write-Host "FAIL  snapshots differ between runs" -ForegroundColor Red; $failures++ }

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Reset/seed is repeatable and seeds the exact expected values." -ForegroundColor Green
