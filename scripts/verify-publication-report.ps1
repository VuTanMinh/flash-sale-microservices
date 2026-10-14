# ============================================================
# Checks the report's Event Publication Reliability section (label sec:outbox)
# against the saved Week 6 evidence and the test plan.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-publication-report.ps1 -OutboxStamp 20261001T163530Z -PublicationStamp 20261001T163055Z
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$OutboxStamp,
    [Parameter(Mandatory = $true)][string]$PublicationStamp
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
$tex = Get-Content (Join-Path $root "report\report.tex") -Raw -Encoding UTF8
$s = $tex.IndexOf("\label{sec:outbox}")
$e = $tex.IndexOf("\section{Inventory Service}", $s)
Check "Event Publication Reliability section found" ($s -gt 0 -and $e -gt $s)
$sec = $tex.Substring($s, $e - $s)

foreach ($pair in @(@("outbox", $OutboxStamp), @("publication", $PublicationStamp))) {
    $log = Get-Content (Join-Path $root "tests\evidence\$($pair[1])-$($pair[0]).log") -Raw -Encoding UTF8
    $pass = ([regex]::Matches($log, '(?m)^PASS')).Count
    $fail = ([regex]::Matches($log, '(?m)^FAIL')).Count
    Check "$($pair[0]) log: exit 0, $pass PASS, $fail FAIL" ($log -match 'Exit code: 0' -and $fail -eq 0)
    Check "report states $pass of $pass checks for $($pair[0]) and cites the log" ($sec.Contains("$pass of $pass checks") -and $sec.Contains("$($pair[1])-$($pair[0]).log"))
}
$pub = Get-Content (Join-Path $root "tests\evidence\$PublicationStamp-publication.log") -Raw -Encoding UTF8
foreach ($case in "A valid route", "B queue missing", "C binding removed", "D broker", "E nack", "F return", "G both queues present", "H OrderProcessed queue missing") {
    Check "evidence contains a passing case '$case'" ($pub -match "PASS  $case")
}
Check "report states the old code fails 8 checks" ($sec.Contains("8 of its checks fail"))
foreach ($topic in "Outbox workflow", "Routed confirmation", "Failure scenarios", "The same guarantee on the real database") {
    Check "report covers: $topic" ($sec.Contains("\paragraph{$topic"))
}
Check "dual-write explanation present" ($sec.Contains("\paragraph{The problem.}") -and $sec.Contains("How the Outbox pattern eliminates both"))
Check "report states mandatory: true and RequiredSubscriberQueues" ($sec.Contains("mandatory: true") -and $sec.Contains("RequiredSubscriberQueues"))
foreach ($stale in "Since`nInventory Service does not exist until Week 7", "verification scaffolding", "this was verified against a real outage, not`nsimulated", "20261001T114318Z-unit-tests.trx") {
    Check "no stale text: '$($stale -replace "`n", ' ')'" (-not $sec.Contains($stale))
}
$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Raw -Encoding UTF8
Check "TP-O01 and TP-O02 are PASS in the test plan" (($plan -match "\| TP-O01 \|[^\n]*\| PASS \|") -and ($plan -match "\| TP-O02 \|[^\n]*\| PASS \|"))

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Event Publication Reliability section matches the Week 6 evidence." -ForegroundColor Green
