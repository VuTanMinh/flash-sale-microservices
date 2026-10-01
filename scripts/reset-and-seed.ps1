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
$db = "flashsale"
$user = "flashsale"
$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptsDir
$composeFile = Join-Path $repoRoot "infra\docker-compose.yml"

function Invoke-SqlFile($path) {
    Get-Content -LiteralPath $path -Raw | docker compose -f $composeFile exec -T postgres psql -U $user -d $db -v ON_ERROR_STOP=1
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed while applying '$path'."
    }
}

Write-Host "Applying baseline schema (idempotent)..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "schema\baseline-schema.sql")

Write-Host "Resetting baseline tables..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "reset.sql")

Write-Host "Seeding known starting inventory..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "seed.sql")

Write-Host "Done. Current inventory:" -ForegroundColor Green
docker compose -f $composeFile exec -T postgres psql -U $user -d $db -c "SELECT * FROM order_service.inventory ORDER BY product_id;"
if ($LASTEXITCODE -ne 0) {
    throw "Could not query the seeded inventory."
}