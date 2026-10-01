# ============================================================
# One-command reset + seed for baseline (C0/C1) experiments.
# Run this before every single experiment run from Week 3 onward.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1 -Container verify-env-pg
#
# Without -Container it targets the Compose "postgres" service; with it, any
# PostgreSQL container (e.g. the throwaway one from verify-environment.ps1).
# Idempotent: safe to run twice in a row -- the second run produces the same
# starting state as the first. Expected values: docs/baseline-c0-c1.md.
# ============================================================
param([string]$Container)

# Continue, not Stop: psql prints NOTICEs on stderr, and Windows PowerShell 5.1
# turns redirected native stderr into terminating errors under Stop. Every
# psql call checks $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"
$db = "flashsale"
$user = "flashsale"
$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptsDir
$composeFile = Join-Path $repoRoot "infra\docker-compose.yml"

function Invoke-Psql([string]$sql) {
    if ($Container) {
        $sql | docker exec -i $Container psql -U $user -d $db -v ON_ERROR_STOP=1 -q
    } else {
        $sql | docker compose -f $composeFile exec -T postgres psql -U $user -d $db -v ON_ERROR_STOP=1 -q
    }
}

function Invoke-SqlFile($path) {
    Invoke-Psql (Get-Content -LiteralPath $path -Raw)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "psql failed while applying '$path'." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Applying baseline schema (idempotent)..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "schema\baseline-schema.sql")

Write-Host "Resetting baseline tables..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "reset.sql")

Write-Host "Seeding known starting inventory..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "seed.sql")

Write-Host "Done. Current inventory:" -ForegroundColor Green
Invoke-Psql "SELECT * FROM order_service.inventory ORDER BY product_id;"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not query the seeded inventory." -ForegroundColor Red
    exit 1
}
