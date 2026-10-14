# ============================================================
# TP-P05 -- verifies that report.tex's Week 11 observability text (the metric
# definitions table, the stage timestamp schema, and the "Replays after
# completion" paragraph) and the Results-chapter templates match the source
# code and the teacher brief (docs/teacher-brief.md section 6 "Metrics").
# No Docker, no services: it reads source files and the report only.
#
#   powershell -NoProfile -File .\scripts\verify-observability-report.ps1
#
# -ReportPath  points the checker at a different report.tex (the negative
#              control: a copy whose timestamp table names a snake_case
#              column and whose Results chapter has a number leaked into a
#              cell). Default: report\report.tex.
# ============================================================
param(
    [string]$ReportPath = "report\report.tex"
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$checks = 0
$failures = 0
$expectedChecks = 25   # number of Check calls in the run (a truncated run must fail)

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    # Count BEFORE any output, and write to the output stream (not the host),
    # so a broken console can never turn a failure into a pass.
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}

# ------------------------------------------------------------------ inputs
$report = if ($ReportPath -match '^[A-Za-z]:[\\/]|^[\\/]') { $ReportPath } else { Join-Path $root $ReportPath }
if (-not (Test-Path -LiteralPath $report)) {
    Write-Output "SETUP ERROR: report not found at $report"
    exit 1
}
$tex = Get-Content -LiteralPath $report -Raw -Encoding UTF8
$srcFiles = @(Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter '*.cs' -File)

# ------------------------------------------------------------------ 1. timestamp schema
$tsLabel = $tex.IndexOf('\label{tab:timestamp-schema}')
$tsEnd = if ($tsLabel -ge 0) { $tex.IndexOf('\end{table}', $tsLabel) } else { -1 }
Check "timestamp schema table found" ($tsLabel -ge 0 -and $tsEnd -gt $tsLabel)
$tsTable = ""
if ($tsLabel -ge 0 -and $tsEnd -gt $tsLabel) { $tsTable = $tex.Substring($tsLabel, $tsEnd - $tsLabel) }

# A column name is the \texttt{...} token that follows \allowbreak; the
# schema/table prefix (orders., outbox_events., order_status_history.) ends
# with a dot and is never right after \allowbreak.
$tsCols = @()
foreach ($m in [regex]::Matches($tsTable, '\\allowbreak\\texttt\{([^}]*)\}')) {
    $tsCols += ($m.Groups[1].Value -replace '\\_', '_')
}
Write-Output "INFO  timestamp table columns: $(@($tsCols) -join ', ')"

$expectedCols = @('RequestAcceptedAt', 'PublishedAt', 'CreatedAt', 'ConfirmedOrRejectedAt', 'At', 'CompletedAt')
$missingCols = @($expectedCols | Where-Object { $tsCols -notcontains $_ })
$extraCols   = @($tsCols | Where-Object { $expectedCols -notcontains $_ })
Check "timestamp table names exactly the six code columns" ($missingCols.Count -eq 0 -and $extraCols.Count -eq 0) "missing: $($missingCols -join ', '); extra: $($extraCols -join ', ')"

# Find the entity files by search, not by hard-coded path, and print them.
$orderCs    = @($srcFiles | Where-Object { $_.Name -eq 'Order.cs' })
$outboxCs   = @($srcFiles | Where-Object { $_.Name -eq 'OutboxEvent.cs' })
$historyCs  = @($srcFiles | Where-Object { $_.Name -eq 'OrderStatusHistory.cs' })
Write-Output "INFO  Order.cs found: $(@($orderCs | ForEach-Object { $_.FullName.Substring($root.Length + 1) }) -join ', ')"
Write-Output "INFO  OutboxEvent.cs found: $(@($outboxCs | ForEach-Object { $_.FullName.Substring($root.Length + 1) }) -join ', ')"
Write-Output "INFO  OrderStatusHistory.cs found: $(@($historyCs | ForEach-Object { $_.FullName.Substring($root.Length + 1) }) -join ', ')"

function Has-Property([string[]]$files, [string]$prop, [int]$want) {
    if ($files.Count -ne $want) { return $false }
    $pat = '\b' + [regex]::Escape($prop) + '\s*\{\s*get'
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        $c = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        if ($c -notmatch $pat) { return $false }
    }
    return $true
}

$orderFiles   = @($orderCs | ForEach-Object { $_.FullName })
$outboxFiles  = @($outboxCs | ForEach-Object { $_.FullName })
$historyFiles = @($historyCs | ForEach-Object { $_.FullName })

Check "RequestAcceptedAt is a property of Order.cs" (Has-Property $orderFiles 'RequestAcceptedAt' 1) "files=$(@($orderCs).Count)"
Check "ConfirmedOrRejectedAt is a property of Order.cs" (Has-Property $orderFiles 'ConfirmedOrRejectedAt' 1) "files=$(@($orderCs).Count)"
Check "CompletedAt is a property of Order.cs" (Has-Property $orderFiles 'CompletedAt' 1) "files=$(@($orderCs).Count)"
Check "PublishedAt is a property of both Outbox entities" (Has-Property $outboxFiles 'PublishedAt' 2) "files=$(@($outboxCs).Count)"
Check "CreatedAt is a property of both Outbox entities" (Has-Property $outboxFiles 'CreatedAt' 2) "files=$(@($outboxCs).Count)"
Check "At is a property of the status-history entity" (Has-Property $historyFiles 'At' 1) "files=$(@($historyCs).Count)"

# ------------------------------------------------------------------ 2. no stale snake_case column names
foreach ($stale in 'request\_accepted\_at', 'confirmed\_or\_rejected\_at', 'completed\_at', 'published\_at') {
    Check "no stale column name '$stale'" (-not $tex.Contains($stale))
}

# ------------------------------------------------------------------ 3. metric definitions table
$mLabel = $tex.IndexOf('\label{tab:metric-definitions}')
$mEnd = if ($mLabel -ge 0) { $tex.IndexOf('\end{table}', $mLabel) } else { -1 }
Check "metric definitions table found" ($mLabel -ge 0 -and $mEnd -gt $mLabel)
$mTable = ""
if ($mLabel -ge 0 -and $mEnd -gt $mLabel) { $mTable = $tex.Substring($mLabel, $mEnd - $mLabel) }

$mid = $mTable.IndexOf('\midrule')
$bot = $mTable.IndexOf('\bottomrule', $mid + 1)
$mData = ""
if ($mid -ge 0 -and $bot -gt $mid) { $mData = $mTable.Substring($mid + '\midrule'.Length, $bot - $mid - '\midrule'.Length) }
$mRows = @($mData -split '\\\\' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
Check "metric table has 17 rows (one per brief metric)" ($mRows.Count -eq 17) "found $($mRows.Count)"

# One keyword per metric in docs/teacher-brief.md section 6 (17 items).
$briefKeywords = @(
    'api latency', 'stock-decision', 'end-to-end completion latency', 'throughput',
    'rejected request rate', 'internal error rate', 'reservation', 'queue depth',
    'oldest message age', 'backlog drain time', 'recovery time', 'retry and duplicate',
    'dlq', 'pending order', 'cpu', 'redis latency', 'rabbitmq'
)
$missingKeywords = @($briefKeywords | Where-Object { $mData.ToLowerInvariant().IndexOf($_) -lt 0 })
Check "metric table covers all 17 brief metrics by keyword" ($missingKeywords.Count -eq 0) "missing: $($missingKeywords -join ', ')"

# Every \texttt{...} token in the metric table must either be one of the
# explicitly-allowed non-metric identifiers below (fields, columns, commands
# or views, not Prometheus metrics) or resolve to flashsale_<base> in BOTH
# src/ and docs/metrics.md. Anything else -- e.g. a misspelled or renamed
# metric -- must fail and be named.
$allowedSkip = @('elapsed', 'CreatedAt', 'CompletedAt', 'orders.State', 'LATENCY', 'INFO commandstats', 'message_stats', 'pg_stat_activity')
$srcMetricNames = @{}
foreach ($f in $srcFiles) {
    $c = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    foreach ($mm in [regex]::Matches($c, 'flashsale_[a-z0-9_]+')) { $srcMetricNames[$mm.Value] = $true }
}
$docMetrics = Get-Content -LiteralPath (Join-Path $root 'docs\metrics.md') -Raw -Encoding UTF8
$docMetricNames = @{}
foreach ($mm in [regex]::Matches($docMetrics, 'flashsale_[a-z0-9_]+')) { $docMetricNames[$mm.Value] = $true }

$cited = @(); $skipped = @()
foreach ($mm in [regex]::Matches($mTable, '\\texttt\{([^}]*)\}')) {
    $name = $mm.Groups[1].Value -replace '\\_', '_' -replace '\\\{', '{' -replace '\\\}', '}'
    $base = $name -replace '\{.*$', ''
    if ($base -match '^process_' -or $allowedSkip -contains $base) { $skipped += $base; continue }
    $cited += $base
}
$cited = @($cited | Select-Object -Unique)
Write-Output "INFO  flashsale metric names cited in the metric table: $($cited -join ', ')"
Write-Output "INFO  allowed non-flashsale identifiers skipped: $(@($skipped | Select-Object -Unique) -join ', ')"

$badMetrics = @()
foreach ($n in $cited) {
    if (-not $srcMetricNames.ContainsKey("flashsale_$n")) { $badMetrics += "$n (not in src/)" }
    if (-not $docMetricNames.ContainsKey("flashsale_$n")) { $badMetrics += "$n (not in docs/metrics.md)" }
}
Check "every Prometheus name in the metric table exists as flashsale_<name> in src and docs/metrics.md" ($badMetrics.Count -eq 0) ($badMetrics -join '; ')

# ------------------------------------------------------------------ 4. Replays-after-completion paragraph
Check "no stale text 'dead-lettered it loudly'" (-not $tex.Contains('dead-lettered it loudly'))

$replayStart = $tex.IndexOf('\paragraph{Replays after completion.}')
$replay = ""
if ($replayStart -ge 0) {
    $replayNext = $tex.IndexOf('\section{', $replayStart + 1)
    if ($replayNext -lt 0) { $replayNext = $tex.Length }
    $replay = $tex.Substring($replayStart, $replayNext - $replayStart)
}
Check "Replays-after-completion paragraph cites TP-P04 and TP-M02" ($replay.Contains('TP-P04') -and $replay.Contains('TP-M02'))

# ------------------------------------------------------------------ 5. Results templates
$rStart = $tex.IndexOf('\chapter{Results}')
$rEnd = $tex.IndexOf('\chapter{Discussion}', $rStart + 1)
$resultsFound = ($rStart -ge 0 -and $rEnd -gt $rStart)
Check "Results chapter found" $resultsFound
$results = ""
if ($resultsFound) { $results = $tex.Substring($rStart, $rEnd - $rStart) }

# Configurations: C0 only in the correctness table; C1/C2/C3 as config rows;
# C4 with 1, 2 and 4 Inventory consumers.
$correctness = ""
$cTab = $results.IndexOf('\label{tab:results-correctness}')
if ($cTab -ge 0) {
    $cEnd = $results.IndexOf('\end{table}', $cTab)
    if ($cEnd -gt $cTab) { $correctness = $results.Substring($cTab, $cEnd - $cTab) }
}
$c0InCorrectness = $correctness.Contains('C0')
$hasC1 = [regex]::IsMatch($results, '(?m)^\s*C1\b')
$hasC2 = [regex]::IsMatch($results, '(?m)^\s*C2\b')
$hasC3 = [regex]::IsMatch($results, '(?m)^\s*C3\b')
$c4Digits = @([regex]::Matches($results, '(?m)^\s*C4[^\r\n]*\b([124])\b') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$c4ok = ($c4Digits -contains '1') -and ($c4Digits -contains '2') -and ($c4Digits -contains '4')
Check "Results cover C0 (correctness only), C1, C2, C3 and C4 with 1/2/4 consumers" ($c0InCorrectness -and $hasC1 -and $hasC2 -and $hasC3 -and $c4ok) "C0-in-correctness=$c0InCorrectness C1=$hasC1 C2=$hasC2 C3=$hasC3 C4-consumers=$($c4Digits -join ',')"

$sixChecks = @('inventory $\ge 0$', 'initial inventory', 'one successful reservation', 'one downstream result', 'terminal', 'add up')
$correctnessLower = $correctness.ToLowerInvariant()
$missingSix = @($sixChecks | Where-Object { $correctnessLower.IndexOf($_.ToLowerInvariant()) -lt 0 })
Check "correctness table has the six brief checks" ($missingSix.Count -eq 0) "missing: $($missingSix -join ', ')"

# Every data cell (the columns after the row label) must be ---, n/a or
# --- / --- / ---: no number may leak in before Week 14.
$cellBad = @()
$tabScan = 0
while (($t1 = $results.IndexOf('\begin{tabular}', $tabScan)) -ge 0) {
    $t2 = $results.IndexOf('\end{tabular}', $t1)
    if ($t2 -lt 0) { break }
    $tab = $results.Substring($t1, $t2 - $t1)
    $tabScan = $t2 + 1
    $midIdx = $tab.IndexOf('\midrule')
    $botIdx = $tab.IndexOf('\bottomrule', $midIdx + 1)
    if ($midIdx -lt 0 -or $botIdx -lt 0) { continue }
    $data = $tab.Substring($midIdx + '\midrule'.Length, $botIdx - $midIdx - '\midrule'.Length)
    $data = $data.Replace('\midrule', '')   # a second \midrule can sit inside the data block
    foreach ($row in ($data -split '\\\\')) {
        $row = $row.Trim()
        if ($row -eq '') { continue }
        $cells = @($row -split '&' | ForEach-Object { $_.Trim() })
        for ($i = 1; $i -lt $cells.Count; $i++) {
            $v = $cells[$i]
            if ($v -ne '---' -and $v -ne 'n/a' -and $v -ne '--- / --- / ---') { $cellBad += $v }
        }
    }
}
Check "every Results data cell is ---, n/a or --- / --- / ---" ($resultsFound -and $cellBad.Count -eq 0) ((@($cellBad | Select-Object -First 5)) -join ', ')

# Exactly 4 figure environments, each still a \fbox placeholder.
$figOk = $true; $figCount = 0; $figScan = 0
while (($f1 = $results.IndexOf('\begin{figure}', $figScan)) -ge 0) {
    $f2 = $results.IndexOf('\end{figure}', $f1)
    if ($f2 -lt 0) { $figOk = $false; break }
    $figCount++
    if (-not $results.Substring($f1, $f2 - $f1).Contains('\fbox')) { $figOk = $false }
    $figScan = $f2 + 1
}
Check "exactly 4 figure environments, each with a \fbox placeholder" ($figCount -eq 4 -and $figOk) "figures=$figCount"

# Every Results table caption says "To be completed in Week~14".
$tables = @(); $tblScan = 0
while (($tb1 = $results.IndexOf('\begin{table}', $tblScan)) -ge 0) {
    $tb2 = $results.IndexOf('\end{table}', $tb1)
    if ($tb2 -lt 0) { break }
    $tables += $results.Substring($tb1, $tb2 - $tb1)
    $tblScan = $tb2 + 1
}
$badCaps = @()
foreach ($tb in $tables) {
    $tbNorm = [regex]::Replace($tb, '\s+', ' ')
    if (-not $tbNorm.Contains('To be completed in Week~14')) { $badCaps += $tb.Substring(0, [Math]::Min(40, $tb.Length)) }
}
Check "every Results table caption says 'To be completed in Week~14'" ($tables.Count -gt 0 -and $badCaps.Count -eq 0) "tables=$($tables.Count) missing=$($badCaps -join ' | ')"

# ------------------------------------------------------------------ 6. no leftover label
Check "no leftover \unverified{TP-P03}" (-not $tex.Contains('\unverified{TP-P03}'))

# ------------------------------------------------------------------ summary
if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: the observability text and Results templates match the code and the brief."
exit 0
