# ============================================================
# Checks that the report's C0/C1 section (report.tex, label sec:c0-c1)
# states what the saved evidence actually shows -- no stale or invented
# numbers. Reads tests/baseline/results/*.json and the C1 smoke JTL.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-baseline-report.ps1 -Stamp 20261001T085538Z -SmokeStamp 20261001T090632Z
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Stamp,
    [Parameter(Mandatory = $true)][string]$SmokeStamp
)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tex = Get-Content (Join-Path $repoRoot "report\report.tex") -Raw -Encoding UTF8
$start = $tex.IndexOf("\label{sec:c0-c1}")
$end = $tex.IndexOf("\section{Order Service}", $start)
$section = $tex.Substring($start, $end - $start)
$results = Join-Path $repoRoot "tests\baseline\results"
$failures = 0

function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
function Has([string]$text) { return $section.Contains($text) }

# C0
$c0 = Get-Content (Join-Path $results "$Stamp-c0-race.json") -Raw | ConvertFrom-Json
Check "C0 evidence verdict is RACE CAPTURED" ($c0.verdict -eq "RACE CAPTURED")
Check "report states C0 $($c0.confirmed) of $($c0.attempts) Confirmed" (Has "Result: $($c0.confirmed) of $($c0.attempts) concurrent requests got 'Confirmed'")
Check "report states C0 final stock $($c0.finalStock)" (Has "Final stock in database: $($c0.finalStock) (started at 1)")
Check "report cites the C0 log file" (Has "$Stamp-c0-race.log")

# C1: every run must pass and match the table row for its scenario
foreach ($scenario in "below", "equal", "above") {
    $runs = @(1..3 | ForEach-Object { Get-Content (Join-Path $results "$Stamp-c1-$scenario-run$_.json") -Raw | ConvertFrom-Json })
    Check "C1 $scenario has 3 runs, all PASS" (@($runs | Where-Object { $_.verdict -eq "PASS" }).Count -eq 3)
    $r = $runs[0]
    $same = @($runs | Where-Object { $_.confirmed -eq $r.confirmed -and $_.rejected -eq $r.rejected -and $_.finalStock -eq $r.finalStock }).Count -eq 3
    Check "C1 $scenario runs agree with each other" $same
    $n = $r.concurrentRequests
    $row = "& $n & $($r.confirmed) & $($r.rejected) & $($r.finalStock) & $n/$n & PASS (3/3 runs)"
    Check "report table row for C1 $scenario matches evidence ($row)" (Has $row)
}
Check "report cites the C1 evidence files" (Has "$Stamp-c1-*-run*.json")

# Smoke JTL
$jtl = @(Import-Csv (Join-Path $repoRoot "tests\jmeter\results\$SmokeStamp-c1-smoke.jtl"))
$elapsed = @($jtl | ForEach-Object { [int]$_.elapsed } | Sort-Object)
$median = if ($elapsed.Count % 2) { $elapsed[[int](($elapsed.Count - 1) / 2)] } else { ($elapsed[$elapsed.Count / 2 - 1] + $elapsed[$elapsed.Count / 2]) / 2 }
Check "JTL: $($jtl.Count) samples, all success, all /api/c1/orders" ($jtl.Count -eq 10 -and @($jtl | Where-Object { $_.success -ne "true" -or $_.URL -notlike "*/api/c1/orders" }).Count -eq 0)
Check "report states min/median/max $($elapsed[0])/$median/$($elapsed[-1]) ms" ((Has "$($elapsed[0])\,ms minimum") -and (Has "$median\,ms median") -and (Has "$($elapsed[-1])\,ms maximum"))
Check "report cites the smoke JTL" (Has "$SmokeStamp-c1-smoke.jtl")

# Stale claims that the new evidence replaced must be gone
Check "no stale 'exactly 1 request Confirmed, 4 Rejected' claim" (-not (Has "exactly 1 request Confirmed"))
Check "no reference to the removed smoke-test-result.jtl" (-not (Has "smoke-test-result.jtl"))

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Report C0/C1 section matches the saved evidence." -ForegroundColor Green
