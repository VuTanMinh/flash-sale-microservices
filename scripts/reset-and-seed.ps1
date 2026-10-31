# ============================================================
# One-command reset + seed for baseline (C0/C1) experiments.
# Run this before every single experiment run from Week 3 onward.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1 -Container verify-env-pg
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1 -Container <pg> -Products @{ 'flash-product-2' = 500 }
#   powershell -ExecutionPolicy Bypass -File .\scripts\reset-and-seed.ps1 -Container <pg> -Full -RedisContainer <redis> -RabbitMqContainer <rabbit>
#
# Without -Container it targets the Compose "postgres" service; with it, any
# PostgreSQL container (e.g. the throwaway one from verify-environment.ps1).
# Idempotent: safe to run twice in a row -- the second run produces the same
# starting state as the first. Expected values: docs/baseline-c0-c1.md.
#
# -Products upserts extra rows (or overrides the seeded stock) into
# order_service.inventory after seed.sql, so a workload can use its own product
# ids and stock levels.
#
# -Full does a complete experiment reset for C2/C3/C4, not just the C0/C1
# baseline: it also clears the async tables (order_service.orders / outbox_events
# / processed_messages / order_status_history and inventory_service.outbox_events
# / processed_messages), flushes Redis and purges every RabbitMQ queue. It has NO
# container defaults: -Container, -RedisContainer and -RabbitMqContainer are all
# required, so a mistyped command cannot flush the owner's local stack.
# docs/teacher-brief.md section 6 requires a full database + Redis reset before
# every experiment.
# ============================================================
param(
    [string]$Container,
    [hashtable]$Products = $null,
    [switch]$Full,
    [string]$RedisContainer = "",
    [string]$RabbitMqContainer = ""
)

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

if ($Full) {
    Write-Host "Full reset: clearing the async (C2/C3/C4) tables, Redis and RabbitMQ..." -ForegroundColor Cyan
    # -Full touches Redis and RabbitMQ, so it must name every container explicitly
    # (no defaults): a mistyped command must not flush the owner's local stack.
    if ([string]::IsNullOrWhiteSpace($Container) -or [string]::IsNullOrWhiteSpace($RedisContainer) -or [string]::IsNullOrWhiteSpace($RabbitMqContainer)) {
        Write-Host "Full reset requires -Container, -RedisContainer and -RabbitMqContainer (no defaults)." -ForegroundColor Red
        exit 2
    }
    # Truncate only the tables that exist (the async tables are created by the
    # services' migrations, so a baseline-only database has none of them).
    $fullResetSql = @'
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'order_service.orders',
    'order_service.outbox_events',
    'order_service.processed_messages',
    'order_service.order_status_history',
    'inventory_service.outbox_events',
    'inventory_service.processed_messages'
  ] LOOP
    IF to_regclass(r) IS NOT NULL THEN
      EXECUTE format('TRUNCATE TABLE %s CASCADE', r);
    END IF;
  END LOOP;
END $$;
'@
    Invoke-Psql $fullResetSql
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Full reset: PostgreSQL truncate of the async tables failed." -ForegroundColor Red
        exit 1
    }

    docker exec $RedisContainer redis-cli FLUSHALL *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Full reset: Redis FLUSHALL failed (container '$RedisContainer')." -ForegroundColor Red
        exit 1
    }

    $mqQueues = @(docker exec $RabbitMqContainer rabbitmqctl -q list_queues name --no-table-headers 2>$null | ForEach-Object { ($_ -split "`t")[0] } | Where-Object { $_ -and ($_ -notmatch '^\s*$') })
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Full reset: RabbitMQ list_queues failed (container '$RabbitMqContainer')." -ForegroundColor Red
        exit 1
    }
    foreach ($q in $mqQueues) {
        docker exec $RabbitMqContainer rabbitmqctl purge_queue $q *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Full reset: RabbitMQ purge of queue '$q' failed." -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host "Seeding known starting inventory..." -ForegroundColor Cyan
Invoke-SqlFile (Join-Path $scriptsDir "seed.sql")

if ($Products -and $Products.Count -gt 0) {
    Write-Host "Upserting -Products into order_service.inventory..." -ForegroundColor Cyan
    $rows = @()
    foreach ($p in @($Products.Keys | Sort-Object)) {
        if ("$p" -notmatch '^[A-Za-z0-9_-]+$') {
            Write-Host "Invalid product id '$p' in -Products." -ForegroundColor Red
            exit 2
        }
        $rows += "('$p', $([int]$Products[$p]))"
    }
    $upsertSql = "INSERT INTO order_service.inventory (product_id, stock) VALUES " + ($rows -join ", ") + " ON CONFLICT (product_id) DO UPDATE SET stock = EXCLUDED.stock;"
    Invoke-Psql $upsertSql
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Upserting -Products failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Done. Current inventory:" -ForegroundColor Green
Invoke-Psql "SELECT * FROM order_service.inventory ORDER BY product_id;"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not query the seeded inventory." -ForegroundColor Red
    exit 1
}
