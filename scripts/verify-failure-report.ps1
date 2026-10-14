# ============================================================
# TP-F03 -- verifies that the report's Week 10 chapter
# "Failure Handling and Recovery (Week 10)" matches the saved
# failure evidence (TP-F01), the reconciliation evidence (TP-F02),
# their two negative controls, docs/failure-handling.md's failure-mode
# table, docs/test-plan.md, and the consumer/config source. No Docker.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-failure-report.ps1 `
#       -FailuresStamp 20261011T084521Z -ReconciliationStamp 20261011T102304Z
#
# -ReportPath  points the checker at a different report.tex (negative control
#              against .agent-tasks/W10-box3-report-before.tex).
# -BuildPdf    also builds the PDF with latexmk.
# -SelfTest    writes a copy of the chapter with one number changed to $env:TEMP
#              and expects the checks to fail.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$FailuresStamp,
    [Parameter(Mandatory = $true)][string]$ReconciliationStamp,
    [string]$ReportPath = "report\report.tex",
    [switch]$BuildPdf,
    [switch]$SelfTest
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$sect = [string][char]0x00A7   # section sign, keeps this file ASCII

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function ReadLog([string]$rel) {
    $p = Join-Path $root $rel
    if (Test-Path $p) { return Get-Content $p -Raw -Encoding UTF8 }
    return ""
}
function Test-GitTracked([string]$rel) {
    & git -C $root ls-files --error-unmatch -- $rel 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Expand-TpIds([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    # Expand TP-A03..A05 ranges first (single/double/triple hyphen, or en/em dash).
    $rangeRe = [regex]'TP-([A-Z])(\d+)\s*(?:--?-?|[\u2013\u2014])\s*([A-Z])(\d+)'
    $expanded = $rangeRe.Replace($text, {
        param($m)
        $out = @()
        for ($n = [int]$m.Groups[2].Value; $n -le [int]$m.Groups[4].Value; $n++) {
            $out += ("TP-{0}{1:D2}" -f $m.Groups[1].Value, $n)
        }
        return ($out -join ', ')
    })
    return @([regex]::Matches($expanded, 'TP-[A-Z]\d+') | ForEach-Object { $_.Value } | Select-Object -Unique)
}

# --- report text -------------------------------------------------------
$report = if ($ReportPath -match '^[A-Za-z]:[\\/]|^[\\/]') { $ReportPath } else { Join-Path $root $ReportPath }
$tex = Get-Content $report -Raw -Encoding UTF8
$s = $tex.IndexOf('\section{Failure Handling and Recovery (Week 10)}')
$e = $tex.IndexOf('\section{', $s + 1)
Check "Week 10 chapter found" ($s -ge 0 -and $e -gt $s)
$sec = ""
if ($s -ge 0 -and $e -gt $s) { $sec = $tex.Substring($s, $e - $s) }

# --- SelfTest: mutate one number BEFORE the checks run -------------------
if ($SelfTest) {
    if ($s -lt 0 -or $e -le $s) {
        Write-Host "SELFTEST FAIL  the Week 10 chapter was not found, so the one-number mutation could not be tested." -ForegroundColor Red
        exit 1
    }
    $mutateRe = [regex]'all (\d+) checks'
    $mutated = $mutateRe.Replace($sec, { param($mm) "all " + ([int]$mm.Groups[1].Value + 1) + " checks" }, 1)
    $selfTestTemp = Join-Path $env:TEMP "W10-box3-report-selftest.tex"
    Set-Content -Path $selfTestTemp -Value $mutated -Encoding UTF8
    $sec = Get-Content $selfTestTemp -Raw -Encoding UTF8
    Write-Host "SELFTEST  chapter copy with one number changed written to $selfTestTemp" -ForegroundColor DarkYellow
}

# --- 1. the four required subsection titles -----------------------------
foreach ($t in 'Classify, then retry a bounded number of times',
    'A dead-letter queue per service, and replay',
    'Reconciliation: stuck orders, a bound and an alert',
    'Supported and unsupported failure modes') {
    Check "subsection title present: $t" ($sec.Contains("\subsection{$t}"))
}

# --- evidence log paths --------------------------------------------------
$f01Log      = "tests/evidence/$FailuresStamp-failures.log"
$f01Neg      = "tests/evidence/$FailuresStamp-failures-negative.log"
$deliveryLog = "tests/evidence/$FailuresStamp-delivery.log"
$orderingLog = "tests/evidence/$FailuresStamp-ordering.log"
$f02Log      = "tests/evidence/$ReconciliationStamp-reconciliation.log"
$f02Neg      = "tests/evidence/$ReconciliationStamp-reconciliation-negative.log"
$requiredLogs = @($f01Log, $f01Neg, $deliveryLog, $orderingLog, $f02Log, $f02Neg)

foreach ($log in $requiredLogs) {
    Check "evidence log exists: $log" (Test-Path (Join-Path $root $log))
    Check "evidence log is git-tracked: $log" (Test-GitTracked $log)
}

# --- 2. numbers match the evidence ---------------------------------------
$f01 = ReadLog $f01Log
$f01Pass = ([regex]::Matches($f01, '(?m)^PASS')).Count
$f01Fail = ([regex]::Matches($f01, '(?m)^FAIL')).Count
Check "failures log has $f01Pass PASS and 0 FAIL" ($f01Pass -gt 0 -and $f01Fail -eq 0)
Check "chapter states all $f01Pass checks for TP-F01" ($sec.Contains("all $f01Pass checks"))

$f01NegText = ReadLog $f01Neg
$f01NegFail = ([regex]::Matches($f01NegText, '(?m)^FAIL')).Count
$words = @('Zero','One','Two','Three','Four','Five','Six','Seven','Eight','Nine','Ten')
$negWord = if ($f01NegFail -ge 1 -and $f01NegFail -le 10) { $words[$f01NegFail] } else { "$f01NegFail" }
Check "failures negative log has $f01NegFail FAIL and the chapter says '$negWord checks'" ($f01NegFail -gt 0 -and $sec.Contains("$negWord checks"))

$m1 = ReadLog $deliveryLog
$m1Pass = ([regex]::Matches($m1, '(?m)^PASS')).Count
$m2 = ReadLog $orderingLog
$m2Pass = ([regex]::Matches($m2, '(?m)^PASS')).Count
Check "chapter states TP-M01 $m1Pass/$m1Pass" ($sec.Contains("TP-M01 $m1Pass/$m1Pass"))
Check "chapter states TP-M02 $m2Pass/$m2Pass" ($sec.Contains("TP-M02 $m2Pass/$m2Pass"))

$f02 = ReadLog $f02Log
$f02Pass = ([regex]::Matches($f02, '(?m)^PASS')).Count
$f02Fail = ([regex]::Matches($f02, '(?m)^FAIL')).Count
Check "reconciliation log has $f02Pass PASS and 0 FAIL" ($f02Pass -gt 0 -and $f02Fail -eq 0)
Check "chapter states all $f02Pass checks for TP-F02" ($sec.Contains("all $f02Pass checks"))

$f02NegText = ReadLog $f02Neg
Check "reconciliation negative log has a FAIL mentioning 'A. lost result'" ($f02NegText -match '(?m)^FAIL.*A\. lost result')

Check "chapter cites the failures log" ($sec.Contains($f01Log))
Check "chapter cites the reconciliation log" ($sec.Contains($f02Log))

# --- 3. configuration matches the text -----------------------------------
$appsettings = Get-Content (Join-Path $root "src\FlashSale.OrderService\appsettings.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$reconMax = [int]$appsettings.Reconciliation.MaxAttempts
$maMatch = [regex]::Match($sec, '\\texttt\{MaxAttempts\}[^\d]*?(\d+)')
$chapterMax = if ($maMatch.Success) { [int]$maMatch.Groups[1].Value } else { -1 }
Check "chapter \texttt{MaxAttempts} equals appsettings ($reconMax)" ($maMatch.Success -and $chapterMax -eq $reconMax) "appsettings=$reconMax chapter=$(if ($maMatch.Success) { $maMatch.Groups[1].Value } else { 'not found' })"

$consumers = @(
    'src\FlashSale.InventoryService\Messaging\OrderPlacedConsumer.cs',
    'src\FlashSale.OrderService\Messaging\StockResultConsumer.cs',
    'src\FlashSale.OrderService\Messaging\OrderProcessedConsumer.cs',
    'src\FlashSale.ProcessWorker\Messaging\StockReservedConsumer.cs'
)
foreach ($c in $consumers) {
    $code = Get-Content (Join-Path $root $c) -Raw -Encoding UTF8
    $rd = [regex]::Match($code, 'RetryDelays\s*=\s*\[(.*?)\]', 'Singleline')
    $delays = @([regex]::Matches($rd.Groups[1].Value, 'TimeSpan\.FromSeconds\((\d+)\)') | ForEach-Object { [int]$_.Groups[1].Value })
    $ma = [regex]::Match($code, 'MaxAttempts\s*=\s*(\d+)')
    $consumerMax = if ($ma.Success) { [int]$ma.Groups[1].Value } else { -1 }
    $okDelays = (($delays -join ',') -eq '1,2,4') -and ($consumerMax -eq 4)
    Check "consumer $(Split-Path -Leaf $c) has RetryDelays 1/2/4 s and MaxAttempts 4" $okDelays "delays=$($delays -join ',') max=$consumerMax"
}
Check "chapter states four attempts" ($sec.Contains('four attempts'))
Check "chapter states the 1\,s, 2\,s and 4\,s ladder" ($sec.Contains('1\,s, 2\,s and 4\,s'))

# --- 4. the failure-mode table matches docs/failure-handling.md -----------
$doc = Get-Content (Join-Path $root "docs\failure-handling.md") -Raw -Encoding UTF8
$dstart = $doc.IndexOf('## Supported and unsupported failure modes')
$docRows = @()
if ($dstart -ge 0) {
    $docSec = $doc.Substring($dstart)
    foreach ($m in [regex]::Matches($docSec, '(?m)^\s*\|\s*F(\d+)\s*\|.*$')) {
        $parts = @($m.Value -split '\|' | ForEach-Object { $_.Trim() })
        $docRows += [PSCustomObject]@{
            Id       = "F" + $m.Groups[1].Value
            Status   = if ($parts.Count -gt 4) { $parts[4] } else { '' }
            Evidence = if ($parts.Count -gt 5) { $parts[5] } else { '' }
        }
    }
}
Check "doc table has 22 rows (F1..F22)" ($docRows.Count -eq 22) "found $($docRows.Count)"

$chapterRows = @()
foreach ($m in [regex]::Matches($sec, 'F(\d+)\s*&(.*?)\\\\')) {
    $cells = @($m.Groups[2].Value -split '&' | ForEach-Object { $_.Trim() })
    $chapterRows += [PSCustomObject]@{
        Id       = "F" + $m.Groups[1].Value
        Status   = if ($cells.Count -gt 2) { $cells[2] } else { '' }
        Evidence = if ($cells.Count -gt 3) { $cells[3] } else { '' }
    }
}

foreach ($dr in $docRows) {
    $cr = $chapterRows | Where-Object { $_.Id -eq $dr.Id } | Select-Object -First 1
    if (-not $cr) {
        Check "failure-mode row $($dr.Id) matches the doc" $false "id missing from the chapter table"
    } elseif ($cr.Status -ne $dr.Status) {
        Check "failure-mode row $($dr.Id) matches the doc" $false "chapter status '$($cr.Status)' != doc '$($dr.Status)'"
    } else {
        Check "failure-mode row $($dr.Id) matches the doc" $true
    }
}

$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Raw -Encoding UTF8
foreach ($dr in ($docRows | Where-Object { $_.Status -eq 'Verified' })) {
    $docIds = Expand-TpIds $dr.Evidence
    $cr = $chapterRows | Where-Object { $_.Id -eq $dr.Id } | Select-Object -First 1
    $notPass = @($docIds | Where-Object { $plan -notmatch ('\| ' + [regex]::Escape($_) + ' \|[^\n]*\| PASS \|') })
    Check "$($dr.Id) cites $(($docIds -join ', ')) all PASS in the test plan" ($notPass.Count -eq 0) ("not PASS: $($notPass -join ', ')")
    if ($cr) {
        $chapterIds = Expand-TpIds $cr.Evidence
        $missing = @($docIds | Where-Object { $chapterIds -notcontains $_ })
        Check "$($dr.Id) chapter cites the same test ids" ($missing.Count -eq 0) ("chapter missing: $($missing -join ', ')")
    } else {
        Check "$($dr.Id) chapter cites the same test ids" $false "chapter row missing"
    }
}

$unbacked = @($chapterRows | Where-Object { $_.Status -eq 'Verified' -and (Expand-TpIds $_.Evidence).Count -eq 0 })
Check "no Verified chapter row lacks a TP id" ($unbacked.Count -eq 0) ($unbacked.Id -join ', ')

# --- 5. out-of-scope items are named -------------------------------------
foreach ($item in 'Redis Cluster', 'RabbitMQ Cluster', 'PostgreSQL replication',
    'multi-region', 'payment', 'compensation', 'Redis data loss', 'ProcessingFailed') {
    Check "chapter names out-of-scope item: $item" ($sec.Contains($item))
}

# --- 6. no stale text ------------------------------------------------------
foreach ($stale in '\unverified', 'to be re-verified', 'not saved as', 'Step 10.', "Proposal ${sect}5") {
    Check "no stale text: '$stale'" (-not $sec.Contains($stale))
}

# --- 7. the PDF builds (only with -BuildPdf) ------------------------------
if ($BuildPdf) {
    Push-Location (Join-Path $root "report")
    try {
        & latexmk -pdf -interaction=nonstopmode -halt-on-error report.tex | Out-Null
        $latexExit = $LASTEXITCODE
        Check "PDF builds (latexmk exit 0)" ($latexExit -eq 0)
        $pdf = Join-Path (Get-Location) "report.pdf"
        $texFile = Join-Path (Get-Location) "report.tex"
        $newer = (Test-Path $pdf) -and (Test-Path $texFile) -and ((Get-Item $pdf).LastWriteTime -gt (Get-Item $texFile).LastWriteTime)
        Check "report.pdf is newer than report.tex" $newer
    }
    finally { Pop-Location }
} else {
    Write-Host "SKIP  PDF build (pass -BuildPdf to enable)" -ForegroundColor DarkYellow
}

# --- summary --------------------------------------------------------------
if ($SelfTest) {
    Write-Host ""
    if ($failures -gt 0) {
        Write-Host "SELFTEST PASS  the one-number copy ($selfTestTemp) failed $failures check(s)." -ForegroundColor Green
        exit 0
    }
    Write-Host "SELFTEST FAIL  the one-number copy ($selfTestTemp) did not fail any check." -ForegroundColor Red
    exit 1
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Week 10 chapter matches the failure evidence." -ForegroundColor Green

