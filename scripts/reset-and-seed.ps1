# ============================================================
# One-command reset + seed for baseline (C0/C1) experiments.
# Run this before every single experiment run from Week 3 onward.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1
#
# Idempotent: safe to run twice in a row -- the second run produces the same
# starting state as the first.
# ============================================================

$ErrorActionPreference = "Stop"
$container = "infra-postgres-1"
$db = "flashsale"
$user = "flashsale"
$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-SqlFile($path) {
    Get-Content $path -Raw | docker exec -i $container psql -U $user -d $db -v ON_ERROR_STOP=1
}

Write-Host "Applying baseline schema (idempotent)..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "schema\baseline-schema.sql")

Write-Host "Resetting baseline tables..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "reset.sql")

Write-Host "Seeding known starting inventory..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "seed.sql")

Write-Host "Done. Current inventory:" -ForegroundColor Green
docker exec $container psql -U $user -d $db -c "SELECT * FROM order_service.inventory ORDER BY product_id;"
