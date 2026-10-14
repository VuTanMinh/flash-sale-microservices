# ============================================================
# Checks the report's Order Service section (label sec:order-service)
# against the saved Week 5 evidence and the test plan.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-order-report.ps1 -Stamp 20261001T123816Z
# ============================================================
param([Parameter(Mandatory = $true)][string]$Stamp)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
$tex = Get-Content (Join-Path $root "report\report.tex") -Raw -Encoding UTF8
$s = $tex.IndexOf("\label{sec:order-service}")
$e = $tex.IndexOf("\subsection{Event Publication Reliability", $s)
Check "Order Service section found" ($s -gt 0 -and $e -gt $s)
$sec = $tex.Substring($s, $e - $s)

# Unit-test evidence
$trxPath = Join-Path $root "tests\evidence\$Stamp-unit-tests.trx"
$trx = Get-Content $trxPath -Raw
$total = [regex]::Match($trx, 'total="(\d+)"').Groups[1].Value
$passed = [regex]::Match($trx, 'passed="(\d+)"').Groups[1].Value
$failed = [regex]::Match($trx, 'failed="(\d+)"').Groups[1].Value
Check "TRX: $passed of $total passed, $failed failed" ($failed -eq "0" -and $passed -eq $total)
Check "report states $passed of $total unit tests" ($sec.Contains("passes, $passed of $total,") -and $sec.Contains("Passed: $passed, Skipped: 0, Total: $total"))
Check "report cites the TRX file" ($sec.Contains("$Stamp-unit-tests.trx"))
Check "TRX contains OrderStateBehaviourTests (TP-A06)" ($trx.Contains("OrderStateBehaviourTests"))

# API evidence
$log = Get-Content (Join-Path $root "tests\evidence\$Stamp-order-api.log") -Raw -Encoding UTF8
$apiPass = ([regex]::Matches($log, '(?m)^PASS')).Count
$apiFail = ([regex]::Matches($log, '(?m)^FAIL')).Count
Check "API log: exit 0, $apiPass PASS, $apiFail FAIL" ($log -match 'Exit code: 0' -and $apiFail -eq 0)
Check "report states $apiPass of $apiPass API checks" ($sec.Contains("$apiPass of $apiPass checks"))
Check "API log shows three concurrent rounds each with one 201 and nineteen 200s" (([regex]::Matches($log, 'no 5xx \((201x1, 200x19|200x19, 201x1)\)')).Count -eq 3)
Check "report states the concurrency result" ($sec.Contains("exactly one 201 and nineteen 200s"))
Check "API log shows the 50-key mixed-load result" ($log -match 'PASS  TP-A07 database: exactly 50 orders and 50')
Check "report states the 50-key result" ($sec.Contains("produced exactly 50") -and $sec.Contains("orders and 50 Outbox rows"))

# Test-case table agrees with the test plan
$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Raw -Encoding UTF8
foreach ($id in "TP-A01", "TP-A02", "TP-A03", "TP-A04", "TP-A05", "TP-A06", "TP-A07") {
    $planPass = $plan -match "\| $id \|[^\n]*\| PASS \|"
    $reportPass = $sec -match "$id & [^\n]*& PASS \\\\"
    Check "$id is PASS in both the test plan and the report table" ($planPass -and $reportPass)
}

# Stale claims gone
foreach ($stale in "there is no event publication yet", "currently has no legal outgoing transition", "Verified manually against the running service", "Passed: 17") {
    Check "no stale claim: '$stale'" (-not $sec.Contains($stale))
}
Check "early OrderProcessed: the Week 9 fix (TP-M02) is stated" ($sec.Contains("fixed in Week 9 (TP-M02)"))

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Order Service report section matches the Week 5 evidence." -ForegroundColor Green
