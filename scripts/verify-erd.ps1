# ============================================================
# Compares docs/erd.md's "Verified schema manifest" with a live database.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-erd.ps1 [-Container infra-postgres-1]
#
# Expects a database built by: infra/initdb roles -> both services'
# migrations -> scripts/reset-and-seed.ps1. Prints one PASS/FAIL line per
# check and exits 1 on any mismatch, so the ERD cannot silently drift from
# the code.
# ============================================================
param(
    [string]$Container = "infra-postgres-1",
    [string]$User = "flashsale",
    [string]$Database = "flashsale"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$erdPath = Join-Path $repoRoot "docs\erd.md"
$script:failures = 0

function Invoke-Sql([string]$sql) {
    # SQL goes in on stdin: Windows PowerShell 5.1 strips embedded double
    # quotes from native-command arguments, which breaks quoted identifiers.
    $out = $sql | docker exec -i $Container psql -U $User -d $Database -At -F "|" -v ON_ERROR_STOP=1 -f -
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $sql" }
    return @($out | Where-Object { $_ -ne "" })
}

function Check([string]$name, $expected, $actual) {
    $e = (@($expected) | Sort-Object) -join ", "
    $a = (@($actual) | Sort-Object) -join ", "
    if ($e -ceq $a) {
        Write-Host "PASS  $name" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $name" -ForegroundColor Red
        Write-Host "      expected: $e"
        Write-Host "      actual:   $a"
        $script:failures++
    }
}

# --- Parse the manifest table out of docs/erd.md -------------------------
$lines = Get-Content -LiteralPath $erdPath -Encoding UTF8
$start = [Array]::IndexOf($lines, "## Verified schema manifest")
if ($start -lt 0) { throw "docs/erd.md has no '## Verified schema manifest' section." }
$manifest = @()
for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -like "## *") { break }
    if ($line -notmatch '^\|\s*(order_service|inventory_service)\.') { continue }
    $cells = $line.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    $manifest += [pscustomobject]@{
        Table   = $cells[0]
        Columns = @($cells[1].Split(',') | ForEach-Object { $_.Trim() })
        Unique  = @(if ($cells[2] -eq '-') { } else { $cells[2].Split(',') | ForEach-Object { $_.Trim() } })
        Owner   = $cells[3]
    }
}
if ($manifest.Count -eq 0) { throw "Manifest table in docs/erd.md is empty." }

$typeMap = @{
    "uuid" = "uuid"; "text" = "text"; "integer" = "integer"; "boolean" = "boolean"; "jsonb" = "jsonb"
    "timestamp without time zone" = "timestamp"; "timestamp with time zone" = "timestamptz"
}

# --- Table set per service schema -----------------------------------------
foreach ($schema in "order_service", "inventory_service") {
    $expected = @($manifest | Where-Object { $_.Table -like "$schema.*" } | ForEach-Object { $_.Table })
    # Order Service keeps its migration history in public (ABP default);
    # Inventory Service's search path puts its own copy in its schema.
    if ($schema -eq "inventory_service") { $expected += "inventory_service.__EFMigrationsHistory" }
    $actual = Invoke-Sql "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname = '$schema'"
    Check "$schema has exactly the documented tables" $expected $actual
}

# --- Per-table columns, unique indexes and owner --------------------------
foreach ($t in $manifest) {
    $schema, $table = $t.Table.Split('.')
    $cols = Invoke-Sql "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = '$schema' AND table_name = '$table'"
    $actualCols = $cols | ForEach-Object {
        $p = $_.Split('|')
        $type = $typeMap[$p[1]]; if (-not $type) { $type = $p[1] }
        "$($p[0]):$type" + $(if ($p[2] -eq 'YES') { '?' } else { '' })
    }
    Check "$($t.Table) columns" $t.Columns $actualCols

    # Unique indexes that are not the primary key, reduced to their column list.
    $uniq = Invoke-Sql @"
SELECT string_agg(a.attname, ',' ORDER BY a.attnum)
FROM pg_index i
JOIN pg_class c ON c.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey)
WHERE n.nspname = '$schema' AND c.relname = '$table' AND i.indisunique AND NOT i.indisprimary
GROUP BY i.indexrelid
"@
    Check "$($t.Table) unique constraints" $t.Unique $uniq

    $owner = Invoke-Sql "SELECT pg_get_userbyid(relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '$schema' AND c.relname = '$table'"
    Check "$($t.Table) owner" $t.Owner $owner
}

# --- No foreign keys anywhere in the service schemas ----------------------
$fks = Invoke-Sql "SELECT conrelid::regclass::text || ' ' || conname FROM pg_constraint WHERE contype = 'f' AND connamespace IN ('order_service'::regnamespace, 'inventory_service'::regnamespace)"
Check "no foreign keys in service schemas" @() $fks

# --- ABP tables in public, owned by Order Service --------------------------
$abp = Invoke-Sql "SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND (tablename LIKE 'Abp%' OR tablename LIKE 'OpenIddict%')"
Check "public holds 37 ABP/OpenIddict tables" @("37") $abp
$publicOther = Invoke-Sql "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND NOT (tablename LIKE 'Abp%' OR tablename LIKE 'OpenIddict%')"
Check "public holds nothing else except Order Service migration history" @("__EFMigrationsHistory") $publicOther
$publicOwners = Invoke-Sql "SELECT DISTINCT pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r'"
Check "public tables owned by order_service_user" @("order_service_user") $publicOwners

# --- Migration history placement ------------------------------------------
$orderHist = Invoke-Sql "SELECT ""MigrationId"" FROM public.""__EFMigrationsHistory"""
$orderExpected = Get-ChildItem (Join-Path $repoRoot "src\FlashSale.OrderService\Migrations") -Filter "*_*.cs" |
    Where-Object { $_.Name -notlike "*.Designer.cs" } | ForEach-Object { $_.BaseName }
Check "Order Service migrations all applied (public history)" $orderExpected $orderHist
$invHist = Invoke-Sql "SELECT ""MigrationId"" FROM inventory_service.""__EFMigrationsHistory"""
$invExpected = Get-ChildItem (Join-Path $repoRoot "src\FlashSale.InventoryService\Migrations") -Filter "*_*.cs" |
    Where-Object { $_.Name -notlike "*.Designer.cs" } | ForEach-Object { $_.BaseName }
Check "Inventory Service migrations all applied (inventory_service history)" $invExpected $invHist

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) failed: docs/erd.md does not match the database." -ForegroundColor Red
    exit 1
}
Write-Host "All checks passed: docs/erd.md matches the database." -ForegroundColor Green
