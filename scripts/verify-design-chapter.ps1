# ============================================================
# Checks the report's System Analysis and Design chapter (Week 4):
# required sections, figures present, API table = exported contract,
# failure-model rows point at real test-plan cases, no unbacked "verified"
# wording, and the teacher-brief points the chapter must carry.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-design-chapter.ps1
# ============================================================
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
$tex = Get-Content (Join-Path $root "report\report.tex") -Raw -Encoding UTF8
$s = $tex.IndexOf("\chapter{System Analysis and Design}")
$e = $tex.IndexOf("\chapter{Implementation}", $s)
$ch = $tex.Substring($s, $e - $s)

foreach ($sec in "Entity-Relationship Diagram", "Class Diagram", "API Contract", "Event Contract", "Order State Machine", "Sequence Diagrams", "Idempotency, Ordering and Ownership", "Design Rationale", "Supported Failure Model") {
    Check "section: $sec" ($ch.Contains("\section{$sec}"))
}
foreach ($fig in [regex]::Matches($ch, '\\includegraphics\[[^\]]*\]\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value }) {
    Check "figure exists and is committed: $fig" ((Test-Path (Join-Path $root "report\$fig")) -and [bool](git -C $root ls-files "report/$fig"))
}

# API table vs exported OpenAPI contract
$api = Get-Content (Join-Path $root "docs\api-contract-v1.json") -Raw | ConvertFrom-Json
$apiSec = $ch.Substring($ch.IndexOf("\section{API Contract}"), $ch.IndexOf("\section{Event Contract}") - $ch.IndexOf("\section{API Contract}"))
foreach ($ep in @(@("/api/orders", "post", "POST /api/orders"), @("/api/orders/{id}", "get", "GET /api/orders/\{id\}"), @("/api/c1/orders", "post", "POST /api/c1/orders"))) {
    $codes = @($api.paths.($ep[0]).($ep[1]).responses.PSObject.Properties.Name | Sort-Object)
    $start = $apiSec.IndexOf("\texttt{$($ep[2])}")
    $next = $apiSec.IndexOf("\texttt{", $start + 10)
    while ($next -ge 0 -and $apiSec.Substring($next, 12) -notmatch '\\texttt\{(POST|GET)') { $next = $apiSec.IndexOf("\texttt{", $next + 8) }
    $block = if ($next -gt 0) { $apiSec.Substring($start, $next - $start) } else { $apiSec.Substring($start) }
    $tableCodes = @([regex]::Matches($block, '& (\d{3}) &') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Check "API table $($ep[2] -replace '\\','') codes ($($tableCodes -join ',')) = contract ($($codes -join ','))" (($tableCodes -join ",") -eq ($codes -join ","))
}

# Failure model rows reference real test cases
$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Raw -Encoding UTF8
$fm = $ch.Substring($ch.IndexOf("\section{Supported Failure Model}"))
$refs = @([regex]::Matches($fm, 'TP-[A-Z]\d\d') | ForEach-Object { $_.Value } | Select-Object -Unique)
Check "failure model references test cases ($($refs.Count))" ($refs.Count -ge 8)
foreach ($r in $refs) { Check "failure model case $r exists in the test plan" ($plan.Contains("| $r |")) }
Check "failure model lists the known gaps" ($fm.Contains("Known gaps in the supported model"))
Check "failure model lists what is not supported" ($fm.Contains("Not supported (out of scope)"))

# No unbacked verification wording in the chapter
foreach ($m in [regex]::Matches($ch, '(?i)verified live|all passing|proven directly')) {
    Check "unbacked claim '$($m.Value)' in chapter" $false
}
$seqSec = $ch.Substring($ch.IndexOf("\section{Sequence Diagrams}"), 1200)
Check "sequence section labels its manual runs as not re-verified" ($seqSec.Contains("\unverified{TP-P03}"))

# Teacher-brief points (docs/teacher-brief.md section 3 and 5)
Check "names all six teacher states" (@("PendingStock", "Confirmed", "Rejected", "Processing", "Completed", "ProcessingFailed" | Where-Object { $ch.Contains("\texttt{$_}") }).Count -eq 6)
Check "ProcessingFailed success-only interpretation stated" ($ch.Contains("success-only"))
Check "schema-per-service stated as not physical isolation" ($ch.Contains("not physical isolation"))
Check "replicas limited to one host (no multi-node claim)" ($ch.Contains("do not show multi-node"))
Check "Process Worker uses order id as idempotency key" ($ch -match 'sets \\texttt\{MessageId\} equal to \\texttt\{OrderId\}')

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "System Analysis and Design chapter is complete and consistent." -ForegroundColor Green
