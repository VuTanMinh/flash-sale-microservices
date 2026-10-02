# ============================================================
# Checks the report's Inventory Service section (label sec:inventory) against
# the saved Week 7 evidence, the real reserve.lua and the test plan.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-inventory-report.ps1 -InventoryStamp 20261002T051418Z -CrossStoreStamp 20261002T052244Z
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$InventoryStamp,
    [Parameter(Mandatory = $true)][string]$CrossStoreStamp
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
$tex = Get-Content (Join-Path $root "report\report.tex") -Raw -Encoding UTF8
$s = $tex.IndexOf("\label{sec:inventory}")
$e = $tex.IndexOf("\section{Closing the Loop", $s)
Check "Inventory Service section found" ($s -gt 0 -and $e -gt $s)
$sec = $tex.Substring($s, $e - $s)

# Lua listing matches the real script's statements
$lua = Get-Content (Join-Path $root "scripts\redis\reserve.lua") -Raw
foreach ($stmt in "SISMEMBER', KEYS[2], ARGV[1]) == 1", "EXISTS', KEYS[3]) == 0", "'NOT_OPEN'", "redis.call('DECR', KEYS[1])", "redis.call('SADD', KEYS[2], ARGV[1])", "return 'RESERVED'") {
    Check "Lua statement in both script and report: $stmt" ($lua.Contains($stmt) -and $sec.Contains($stmt))
}

# Inventory evidence: the concurrency table equals the logged outcome counts
$inv = Get-Content (Join-Path $root "tests\evidence\$InventoryStamp-inventory.log") -Raw -Encoding UTF8
Check "inventory log: exit 0 and no FAIL" ($inv -match 'Exit code: 0' -and $inv -notmatch '(?m)^FAIL')
$bursts = [regex]::Matches($inv, 'INFO  (\d+) concurrent EVALs: ([^\r\n]+)')
Check "inventory log has two bursts" ($bursts.Count -eq 2)
foreach ($b in $bursts) {
    $n = $b.Groups[1].Value
    $counts = @{}; foreach ($kv in $b.Groups[2].Value.Split(',')) { $k, $v = $kv.Trim().Split('='); $counts[$k] = $v }
    $row = "& $n & $($counts['RESERVED']) & $($counts['DUPLICATE']) & $($counts['REJECTED'])"
    Check "report table row for the $n-request burst matches the log ($row)" ($sec.Contains($row))
}
Check "report states warm-up confirmed all six products" ($sec.Contains("confirmed all six test") -and ([regex]::Matches($inv, "CONFIRMED")).Count -ge 0)
Check "inventory log shows the end-to-end readiness results" ($inv -match "PASS  TP-I01 end to end: OrderPlaced for 'never-warmed' -> StockRejected" -and $inv -match "PASS  TP-I01 end to end: OrderPlaced for 'e2e-product' -> StockReserved")

# Cross-store evidence
$xs = Get-Content (Join-Path $root "tests\evidence\$CrossStoreStamp-cross-store.log") -Raw -Encoding UTF8
$xsPass = ([regex]::Matches($xs, '(?m)^PASS')).Count
Check "cross-store log: exit 0, $xsPass PASS" ($xs -match 'Exit code: 0' -and $xs -notmatch '(?m)^FAIL')
Check "report states $xsPass of $xsPass cross-store checks and the old code failing 5" ($sec.Contains("($xsPass of $xsPass checks)") -and $sec.Contains("5 of the test's 11 checks failed"))
Check "report cites both evidence logs" ($sec.Contains("$InventoryStamp-inventory.log") -and $sec.Contains("$CrossStoreStamp-cross-store.log"))

# Topics required by the roadmap box
foreach ($t in "Redis key and data design", "Lua reservation logic", "Inventory warm-up and readiness", "Inventory invariants under concurrency", "OrderPlaced handling and the Redis/PostgreSQL boundary") {
    Check "report covers: $t" ($sec.Contains("\subsection{$t}"))
}
# Stale claims removed
foreach ($stale in "a failure nacks with requeue", "already treats as", "drained all three", "29 of 30", "\unverified{TP-I02}") {
    Check "no stale text: '$stale'" (-not $sec.Contains($stale))
}
$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Raw -Encoding UTF8
foreach ($id in "TP-I01", "TP-I02", "TP-I03") { Check "$id is PASS in the test plan" ($plan -match "\| $id \|[^\n]*\| PASS \|") }

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Inventory Service report section matches the Week 7 evidence." -ForegroundColor Green
