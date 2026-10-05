# ============================================================
# TP-M03 -- verifies that the report's Week 9 chapter
# "Reliability and Idempotency Layer (Week 9)" (sec:week9) matches the
# saved delivery evidence (TP-M01), the ordering evidence (TP-M02), the
# three negative controls and docs/test-plan.md. No Docker needed.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-delivery-report.ps1 `
#       -DeliveryStamp 20261002T183238Z -OrderingStamp 20261003T181814Z
#
# -ReportPath  points the checker at a different report.tex (negative control
#              against git HEAD). -Compile also builds the PDF.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$DeliveryStamp,
    [Parameter(Mandatory = $true)][string]$OrderingStamp,
    [string]$ReportPath = "",
    [switch]$Compile
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function ReadLog([string]$rel) {
    $p = Join-Path $root $rel
    if (Test-Path $p) { return Get-Content $p -Raw -Encoding UTF8 }
    return ""
}

# --- report text -------------------------------------------------------
if ($ReportPath) { $report = (Resolve-Path $ReportPath).Path }
else { $report = Join-Path $root "report\report.tex" }
$tex = Get-Content $report -Raw -Encoding UTF8
$s = $tex.IndexOf('\section{Reliability and Idempotency Layer (Week 9)}')
$e = $tex.IndexOf('\section{', $s + 1)
Check "Week 9 chapter found" ($s -ge 0 -and $e -gt $s)
$sec = $tex.Substring($s, $e - $s)

# --- 1. the four required subsection titles ----------------------------
foreach ($t in 'Message delivery semantics', 'Idempotent consumer',
    'Acknowledgement strategy, proven with a real crash (Step 9.3)',
    'Duplicate handling') {
    Check "subsection title present: $t" ($sec.Contains("\subsection{$t}"))
}

# --- 2. required content ------------------------------------------------
foreach ($phrase in 'at-least-once', 'effectively once', 'unique violation',
    'NotYetApplicable', 'no Inbox') {
    Check "chapter mentions: $phrase" ($sec.Contains($phrase))
}
# Long class names are split with \allowbreak in the LaTeX source
# (e.g. \texttt{StockReserved}\allowbreak\texttt{Consumer}); unwrap the
# markup so each class name is found as one contiguous string.
$plain = $sec.Replace('\allowbreak', '').Replace('\texttt{', '').Replace('\emph{', '').Replace('{', '').Replace('}', '')
foreach ($c in 'OrderPlacedConsumer', 'StockResultConsumer', 'OrderProcessedConsumer', 'StockReservedConsumer') {
    Check "chapter names the consumer class $c" ($plain.Contains($c))
}

# --- 3. evidence files exist and are committed (git ls-files) ----------
$tracked = @(git -C $root ls-files -- tests/evidence)
$deliveryLog = "tests/evidence/$DeliveryStamp-delivery.log"
$orderingLog = "tests/evidence/$OrderingStamp-delivery-ordering.log"
$orderingNeg = "tests/evidence/$OrderingStamp-delivery-ordering-negative-early-completion.log"
Check "delivery log is committed ($deliveryLog)" ($tracked -contains $deliveryLog)
Check "ordering log is committed ($orderingLog)" ($tracked -contains $orderingLog)
Check "ordering negative-control log is committed ($orderingNeg)" ($tracked -contains $orderingNeg)
$delNeg = @($tracked | Where-Object { $_ -like "tests/evidence/$DeliveryStamp-delivery-negative-*.log" } | Sort-Object)
Check "exactly two delivery negative-control logs are committed" ($delNeg.Count -eq 2)

# --- 4. numbers match the evidence -------------------------------------
$m1 = ReadLog $deliveryLog
$m1Pass = ([regex]::Matches($m1, '(?m)^PASS')).Count
$m1Fail = ([regex]::Matches($m1, '(?m)^FAIL')).Count
Check "delivery log: exit 0, $m1Pass PASS, $m1Fail FAIL" ($m1 -match 'exit code: 0' -and $m1Fail -eq 0)
Check "report states $m1Pass of $m1Pass checks for TP-M01 and cites the delivery log" ($sec.Contains("passes $m1Pass of $m1Pass") -and $sec.Contains("$DeliveryStamp-delivery.log"))

$m2 = ReadLog $orderingLog
$m2Pass = ([regex]::Matches($m2, '(?m)^PASS')).Count
$m2Fail = ([regex]::Matches($m2, '(?m)^FAIL')).Count
Check "ordering log: exit 0, $m2Pass PASS, $m2Fail FAIL" ($m2 -match 'exit code: 0' -and $m2Fail -eq 0)
Check "report states $m2Pass of $m2Pass checks for TP-M02 and cites the ordering log" ($sec.Contains("passes $m2Pass of $m2Pass") -and $sec.Contains("$OrderingStamp-delivery-ordering.log"))

$negAckPath = $delNeg | Where-Object { $_ -match 'ack' } | Select-Object -First 1
$negInboxPath = $delNeg | Where-Object { $_ -match 'inbox' } | Select-Object -First 1
$negAck = if ($negAckPath) { ReadLog $negAckPath } else { "" }
$negInbox = if ($negInboxPath) { ReadLog $negInboxPath } else { "" }
$negOrd = ReadLog $orderingNeg
$negAckFail = ([regex]::Matches($negAck, '(?m)^FAIL')).Count
$negInboxFail = ([regex]::Matches($negInbox, '(?m)^FAIL')).Count
$negOrdFail = ([regex]::Matches($negOrd, '(?m)^FAIL')).Count
Check "ack negative log: $negAckFail FAIL, exit 1" ($negAck -match 'exit code: 1' -and $negAckFail -gt 0)
Check "report states the ack negative failed $negAckFail of $m1Pass checks" ($sec.Contains("failed $negAckFail of its $m1Pass checks"))
Check "inbox negative log: $negInboxFail FAIL, exit 1" ($negInbox -match 'exit code: 1' -and $negInboxFail -gt 0)
Check "report states the inbox negative failed exactly one check" ($negInboxFail -eq 1 -and $sec.Contains('exactly one check failed'))
Check "ordering negative log: $negOrdFail FAIL, exit 1" ($negOrd -match 'exit code: 1' -and $negOrdFail -gt 0)
Check "report states the ordering negative failed $negOrdFail checks" ($sec.Contains("$negOrdFail checks failed"))

$unit = ReadLog "tests/evidence/$OrderingStamp-unit-tests.log"
$unitTotal = ([regex]::Match($unit, 'Total:\s*(\d+)')).Groups[1].Value
Check "unit-tests log: 0 failed, Total = $unitTotal" ($unit -match 'Failed:\s*0' -and $unitTotal -ne '')
Check "report states the unit-test total $unitTotal" ($sec.Contains("has $unitTotal tests"))

# --- 5. TP-M01 and TP-M02 are cited and PASS in the test plan ----------
$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Raw -Encoding UTF8
Check "TP-M01 is cited in the chapter" ($sec.Contains('TP-M01'))
Check "TP-M02 is cited in the chapter" ($sec.Contains('TP-M02'))
Check "TP-M01 is PASS in the test plan" ($plan -match '\| TP-M01 \|[^\n]*\| PASS \|')
Check "TP-M02 is PASS in the test plan" ($plan -match '\| TP-M02 \|[^\n]*\| PASS \|')

# --- 6. no stale or unbacked text in the chapter -----------------------
foreach ($stale in "Both consumers' actual correctness logic", 'confirmed directly:', 'currently has 43 tests') {
    Check "no stale text: '$stale'" (-not $sec.Contains($stale))
}
Check 'no \unverified in the chapter' (-not $sec.Contains('\unverified{'))

# --- 7. the PDF builds (only with -Compile) ----------------------------
if ($Compile) {
    Push-Location (Join-Path $root "report")
    try {
        & latexmk -pdf -interaction=nonstopmode -halt-on-error report.tex | Out-Null
        Check "PDF builds (latexmk exit 0)" ($LASTEXITCODE -eq 0)
    }
    finally { Pop-Location }
}
else {
    Write-Host "SKIP  PDF build (pass -Compile to enable)" -ForegroundColor DarkYellow
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Week 9 chapter matches the delivery evidence." -ForegroundColor Green
