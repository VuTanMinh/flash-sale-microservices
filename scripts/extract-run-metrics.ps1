# ============================================================
# Week 11 milestone, Task C: extract one run's raw data into the numbers the
# report Results tables (Chapter 12, tab:results-*) ask for, with every
# definition fixed before the pilot. This is the "one extraction query/script
# per metric" the W11 milestone needs (Notion 04).
#
#   powershell -File .\scripts\extract-run-metrics.ps1 -RunId pilot-001 -Container verify-env-pg
#
# Inputs:
#   -RunId        name of the run; also the folder under experiments/ by default.
#   -RunDir       where raw data lives and outputs go (default experiments/<RunId>).
#   -JtlPath      JMeter CSV (default <RunDir>/raw.jtl). Optional: if the file is
#                 absent the JTL block is reported unavailable and -From/-To are
#                 required.
#   -From/-To     UTC window of the run (default: first and last JTL sample).
#   -Container    PostgreSQL container (docker exec), for the database block.
#   -SubmissionLabelPattern / -PollingLabelPattern
#                 how a JTL row is classed as a submission or a polling request
#                 (case-insensitive substring match on the sampler label). The
#                 JMeter plan must label samplers so these match; defaults are
#                 "submit" and "poll".
#   -StableRange  optional hashtable of pilot-defined thresholds for recovery
#                 time (keys max_p95_ms, max_error_pct, min_throughput_per_s =
#                 accepted 2xx per second, and optionally max_refused_pct,
#                 max_outbox_backlog and max_total_backlog). Without it recovery
#                 time is "unavailable", never 0.
#   -OverloadEnd / -RecoveryLabelPattern / -StableWindowSeconds
#                 when the overload was removed (default: the first submission
#                 labelled "recovery") and how long a window must stay in the
#                 stable range (default 10 s) for recovery to count.
#
# Run membership: with an idempotencyKey column in the JTL, the database block
# counts exactly the orders whose key the run submitted; otherwise it falls
# back to the acceptance time window. summary.json says which was used.
#
# Outputs (both written to <RunDir>/):
#   summary.json         every metric with its value; each group carries a
#                        "source" naming where the number came from.
#   stage-intervals.csv  one row per accepted order: order_id, state and the five
#                        stage intervals in milliseconds (empty = missing).
# A readable summary is printed to the console.
#
# Percentile method: nearest-rank -- p_k = the value at rank ceil(k/100 * n) in
# the sorted (non-missing) list, 1-based. Negative intervals are kept (reported,
# never clamped) and counted; missing values are counted, never guessed.
#
# Exit codes: 0 success; 1 fatal setup (no run dir, no window); 2 a database
# query failed after the reachability probe (summary.json is still written).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$RunDir = "",
    [string]$JtlPath = "",
    [string]$From = "",
    [string]$To = "",
    [string]$Container = "",
    [string]$SubmissionLabelPattern = "submit",
    [string]$PollingLabelPattern = "poll",
    [hashtable]$StableRange = $null,
    [string]$OverloadEnd = "",
    [string]$RecoveryLabelPattern = "recovery",
    [int]$StableWindowSeconds = 10
)

# Continue, not Stop: under Windows PowerShell 5.1, redirected stderr from a
# native command (docker) becomes a terminating error under Stop.
$ErrorActionPreference = "Continue"
$inv = [Globalization.CultureInfo]::InvariantCulture

if ($RunDir -eq "") { $RunDir = Join-Path (Join-Path (Get-Location).Path "experiments") $RunId }
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { Write-Output "FATAL: cannot create $RunDir"; exit 1 }
if ($JtlPath -eq "") { $JtlPath = Join-Path $RunDir "raw.jtl" }

$summaryJsonPath = Join-Path $RunDir "summary.json"
$intervalsCsvPath = Join-Path $RunDir "stage-intervals.csv"

# ------------------------------------------------------------------ helpers
function Fmt([double]$v) { return $v.ToString("R", $inv) }

# Parse a CSV numeric value with the invariant culture; $null when the field is
# not a number (for example "unavailable").
function Num([string]$s) { if ($null -eq $s -or $s -eq "") { return $null }; try { return [double]::Parse($s, $inv) } catch { return $null } }

# Parse a utc_time value (yyyy-MM-ddTHH:mm:ss.fffZ); $null on failure. Parse as
# UTC, not local: AssumeUniversal + AdjustToUniversal so a "...Z" string stays UTC
# regardless of the host's time zone.
function Time([string]$s) { if ($null -eq $s -or $s -eq "") { return $null }; try { return [DateTime]::Parse($s, $inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') } catch { return $null } }

# True when the ";"-joined key=value list contains exactly the given "k=v".
function HasLabel([string]$labels, [string]$kv) {
    if ($null -eq $labels) { return $false }
    foreach ($part in ($labels -split ';')) { if ($part -eq $kv) { return $true } }
    return $false
}
# The value after "key=" in a ";"-joined key=value list, or "" when absent.
function LabelValue([string]$labels, [string]$key) {
    if ($null -eq $labels) { return "" }
    foreach ($part in ($labels -split ';')) {
        if ($part -like "$key=*") { return $part.Substring($key.Length + 1) }
    }
    return ""
}

# Nearest-rank percentile over an already-sorted list. p is 0..100.
function PercentileRank([double[]]$sorted, [double]$p) {
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    $rank = [int][math]::Ceiling($p / 100.0 * $n)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $n) { $rank = $n }
    return $sorted[$rank - 1]
}
# Percentiles + negative/missing counts over an unsorted list of present values.
# Returns a hashtable: p50, p95, p99, max, negative_count. present=0 -> all null.
function Summarize([double[]]$values) {
    $r = @{ p50 = $null; p95 = $null; p99 = $null; max = $null; negative_count = 0 }
    if ($values.Count -eq 0) { return $r }
    $sorted = @($values | Sort-Object)
    $r.p50 = PercentileRank $sorted 50
    $r.p95 = PercentileRank $sorted 95
    $r.p99 = PercentileRank $sorted 99
    $r.max = $sorted[$sorted.Count - 1]
    $neg = 0
    foreach ($v in $values) { if ($v -lt 0) { $neg++ } }
    $r.negative_count = $neg
    return $r
}
# Reset-aware increase over a time-ordered list of cumulative counter values.
function CounterIncrease([double[]]$values) {
    $inc = 0.0; $prev = $null
    foreach ($v in $values) {
        if ($null -ne $prev) {
            if ($v -ge $prev) { $inc += ($v - $prev) } else { $inc += $v }
        }
        $prev = $v
    }
    return $inc
}
function MeanPeak([double[]]$values) {
    if ($values.Count -eq 0) { return @{ mean = $null; peak = $null } }
    $sum = 0.0; $peak = $values[0]
    foreach ($v in $values) { $sum += $v; if ($v -gt $peak) { $peak = $v } }
    return @{ mean = ($sum / $values.Count); peak = $peak }
}
# Throws when psql (or docker exec) fails, so a failed query can never be read
# as an empty result and cast to 0. Only the reachability probe below catches it.
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    $code = $LASTEXITCODE
    $text = (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
    if ($code -ne 0) { throw "SQL failed (exit $code): $text" }
    return $text
}
function SqlTs([DateTime]$d) { return $d.ToString('yyyy-MM-dd HH:mm:ss.ffffff', $inv) }

# Returns an integer from a SQL query whose result is used as a number. The
# result must be exactly one line holding an integer, or this throws, so a
# failed or empty query can never be read (and cast) as 0. (Review finding C4.)
function SqlInt([string]$sql) {
    $text = Sql $sql
    $lines = @($text -split "`n" | Where-Object { $_ -ne "" })
    if ($lines.Count -ne 1) { throw "SQL shape error: expected one line, got $($lines.Count)" }
    $line = ([string]$lines[0]).Trim()
    if ($line -notmatch '^-?\d+$') { throw "SQL shape error: not an integer '$line'" }
    return [int]$line
}

# The latest point (t, v) in an ascending list at or before $at, or $null.
function LastPointAtOrBefore($points, [DateTime]$at) {
    $last = $null
    foreach ($p in $points) { if ($p.t -le $at) { $last = $p } else { break } }
    return $last
}

# ------------------------------------------------------------------ window
$windowFrom = $null; $windowTo = $null
$jtlRows = @()
if (Test-Path -LiteralPath $JtlPath) { $jtlRows = @(Import-Csv -LiteralPath $JtlPath) }

if ($From -ne "") { $windowFrom = [DateTime]::Parse($From, $inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
if ($To -ne "") { $windowTo = [DateTime]::Parse($To, $inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }

if ($null -eq $windowFrom -or $null -eq $windowTo) {
    # default: first and last JTL sample
    $ts = @()
    foreach ($r in $jtlRows) {
        $t = $null
        if ($null -ne $r.timeStamp -and $r.timeStamp -ne "") {
            try { $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$r.timeStamp).UtcDateTime } catch { $t = $null }
        }
        if ($null -ne $t) { $ts += $t }
    }
    if ($ts.Count -eq 0) { Write-Output "FATAL: no JTL samples and no -From/-To; cannot determine the run window"; exit 1 }
    if ($null -eq $windowFrom) { $windowFrom = ($ts | Sort-Object)[0] }
    if ($null -eq $windowTo) { $windowTo = ($ts | Sort-Object)[-1] }
}

# ------------------------------------------------------------------ JTL
function JtlTime([object]$r) {
    if ($null -eq $r.timeStamp -or $r.timeStamp -eq "") { return $null }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$r.timeStamp).UtcDateTime } catch { return $null }
}
$subElapsed = @(); $pollElapsed = @()
$subCount = 0; $pollCount = 0
$runKeys = New-Object System.Collections.Generic.HashSet[string]
$subSamples = New-Object System.Collections.Generic.List[object]   # t, code, elapsed, label (for recovery)
$overloadCount = 0; $internalErrorCount = 0; $otherNon2xxCount = 0
$subTimes = @()
foreach ($r in $jtlRows) {
    $t = JtlTime $r
    if ($null -eq $t -or $t -lt $windowFrom -or $t -gt $windowTo) { continue }
    $label = [string]$r.label
    $code = [string]$r.responseCode
    $isSub = ($label -match $SubmissionLabelPattern)
    $isPoll = ($label -match $PollingLabelPattern)
    if ($isSub) {
        $subCount++
        $subTimes += $t
        $el = Num ([string]$r.elapsed)
        if ($null -ne $el) { $subElapsed += $el }
        $key = [string]$r.idempotencyKey
        if ($key -ne "") { [void]$runKeys.Add($key) }
        $subSamples.Add([pscustomobject]@{ t = $t; code = $code; elapsed = $el; label = $label })
        if ($code -eq "429" -or $code -eq "503") { $overloadCount++ }
        elseif ($code -match '^5\d\d$' -and $code -ne "503") { $internalErrorCount++ }
        elseif ($code -notmatch '^2\d\d$') { $otherNon2xxCount++ }
    } elseif ($isPoll) {
        $pollCount++
        $el = Num ([string]$r.elapsed)
        if ($null -ne $el) { $pollElapsed += $el }
    }
}
$subPct = Summarize @($subElapsed)
$pollPct = Summarize @($pollElapsed)
$windowSeconds = 0.0
if ($null -ne $windowFrom -and $null -ne $windowTo) { $windowSeconds = ($windowTo - $windowFrom).TotalSeconds }
$offeredThroughput = $null
if ($windowSeconds -gt 0) { $offeredThroughput = $subCount / $windowSeconds }
$overloadPct = $null; if ($subCount -gt 0) { $overloadPct = $overloadCount * 100.0 / $subCount }
$internalErrorPct = $null; if ($subCount -gt 0) { $internalErrorPct = $internalErrorCount * 100.0 / $subCount }
$otherNon2xxPct = $null; if ($subCount -gt 0) { $otherNon2xxPct = $otherNon2xxCount * 100.0 / $subCount }
$lastSubmission = $null
if ($subTimes.Count -gt 0) { $lastSubmission = ($subTimes | Sort-Object)[-1] }

$jtlBlock = [ordered]@{
    source = "raw.jtl ($JtlPath)"
    submission_count = $subCount
    submission_elapsed_ms = [ordered]@{ source = "raw.jtl elapsed (nearest-rank)"; p50 = $subPct.p50; p95 = $subPct.p95; p99 = $subPct.p99; max = $subPct.max }
    offered_throughput_per_s = $offeredThroughput
    overload_rejection_pct = $overloadPct
    internal_error_pct = $internalErrorPct
    other_non_2xx_pct = $otherNon2xxPct
    polling_count = $pollCount
    polling_elapsed_ms = [ordered]@{ source = "raw.jtl elapsed (nearest-rank)"; p50 = $pollPct.p50; p95 = $pollPct.p95; p99 = $pollPct.p99; max = $pollPct.max }
}
if (-not (Test-Path -LiteralPath $JtlPath)) {
    $jtlBlock.source = "raw.jtl ($JtlPath) -- MISSING"
    $jtlBlock.submission_count = "unavailable"
    $jtlBlock.offered_throughput_per_s = "unavailable"
    $jtlBlock.overload_rejection_pct = "unavailable"
    $jtlBlock.internal_error_pct = "unavailable"
    $jtlBlock.other_non_2xx_pct = "unavailable"
    $jtlBlock.polling_count = "unavailable"
}

# ------------------------------------------------------------------ database
$dbBlock = $null
$dbOk = $false
$dbBlockFailed = $false
$drainDbFailed = $false
$dbFailedReason = ""
if ($Container -ne "") {
    try { if ((Sql "SELECT 1;") -eq "1") { $dbOk = $true } } catch { }
    if (-not $dbOk) {
        $dbBlock = "unavailable (container '$Container' not reachable)"
    } else {
        try {
        $fromSql = SqlTs $windowFrom
        $toSql = SqlTs $windowTo

        # Which orders belong to this run. When the JTL carries the
        # Idempotency-Key of each submission (JMeter -Jsample_variables=
        # idempotencyKey), an order is in the run exactly when its key was
        # submitted by it: no timing edge at either end, and no stray order
        # from another client. Without keys, fall back to the acceptance time
        # window (older plans), and say so in summary.json.
        $safeKeys = @($runKeys | Where-Object { $_ -match '^[A-Za-z0-9-]{1,100}$' })
        if ($safeKeys.Count -gt 0) {
            $keyArray = "ARRAY['" + ($safeKeys -join "','") + "']::text[]"
            $member = "`"IdempotencyKey`" = ANY($keyArray)"
            $memberO = "o.`"IdempotencyKey`" = ANY($keyArray)"
            $membership = "jtl idempotencyKey ($($safeKeys.Count) submitted keys)"
        } else {
            $member = "`"RequestAcceptedAt`" >= '$fromSql' AND `"RequestAcceptedAt`" <= '$toSql'"
            $memberO = "o.`"RequestAcceptedAt`" >= '$fromSql' AND o.`"RequestAcceptedAt`" <= '$toSql'"
            $membership = "acceptance time window (no idempotencyKey column in the JTL)"
        }

        $accepted = SqlInt "SELECT count(*) FROM order_service.orders WHERE $member;"
        $completed = SqlInt "SELECT count(*) FROM order_service.orders WHERE $member AND `"State`" = 'Completed';"
        $pending = SqlInt "SELECT count(*) FROM order_service.orders WHERE $member AND `"State`" IN ('PendingStock','Confirmed','Processing');"
        $stateLines = @((Sql "SELECT `"State`" || '|' || count(*) FROM order_service.orders WHERE $member GROUP BY `"State`" ORDER BY `"State`";") -split "`n" | Where-Object { $_ -ne "" })
        $stateCounts = [ordered]@{}
        foreach ($line in $stateLines) {
            $parts = @($line -split '\|')
            if ($parts.Count -ge 2) { $stateCounts[[string]$parts[0]] = [int]$parts[1] }
        }

        # One row per accepted order: id|state|accepted|orderPublished|invCreated|applied|completed.
        # Exactly one row per order: reconciliation re-publishes a stuck order
        # by adding another OrderPlaced Outbox row, so a plain join would repeat
        # the order once per re-trigger. The stage times come from the ORIGINAL
        # OrderPlaced row and the first Inventory result row (earliest CreatedAt).
        $stageSql = @"
SELECT o."Id"::text || '|' || o."State" || '|' ||
       to_char(o."RequestAcceptedAt", 'YYYY-MM-DD HH24:MI:SS.US') || '|' ||
       coalesce(to_char(op."PublishedAt", 'YYYY-MM-DD HH24:MI:SS.US'), '') || '|' ||
       coalesce(to_char(io."CreatedAt", 'YYYY-MM-DD HH24:MI:SS.US'), '') || '|' ||
       coalesce(to_char(o."ConfirmedOrRejectedAt", 'YYYY-MM-DD HH24:MI:SS.US'), '') || '|' ||
       coalesce(to_char(o."CompletedAt", 'YYYY-MM-DD HH24:MI:SS.US'), '')
FROM order_service.orders o
LEFT JOIN LATERAL (SELECT x."PublishedAt" FROM order_service.outbox_events x
                   WHERE x."OrderId" = o."Id" AND x."EventType" = 'OrderPlaced'
                   ORDER BY x."CreatedAt", x."Id" LIMIT 1) op ON true
LEFT JOIN LATERAL (SELECT y."CreatedAt" FROM inventory_service.outbox_events y
                   WHERE y."OrderId" = o."Id"
                   ORDER BY y."CreatedAt", y."Id" LIMIT 1) io ON true
WHERE $memberO
ORDER BY o."RequestAcceptedAt";
"@
        $stageLines = @((Sql $stageSql) -split "`n" | Where-Object { $_ -ne "" })

        # parse each stage line; build the intervals CSV and the per-stage value lists
        $csvLines = New-Object System.Collections.Generic.List[string]
        $csvLines.Add("order_id,state,accepted_to_published_ms,published_to_decided_ms,decided_to_applied_ms,applied_to_completed_ms,accepted_to_completed_ms")
        $stageValues = [ordered]@{
            accepted_to_published  = New-Object System.Collections.Generic.List[double]
            published_to_decided   = New-Object System.Collections.Generic.List[double]
            decided_to_applied     = New-Object System.Collections.Generic.List[double]
            applied_to_completed   = New-Object System.Collections.Generic.List[double]
            accepted_to_completed  = New-Object System.Collections.Generic.List[double]
        }
        $missing = [ordered]@{ accepted_to_published = 0; published_to_decided = 0; decided_to_applied = 0; applied_to_completed = 0; accepted_to_completed = 0 }

        foreach ($line in $stageLines) {
            $parts = @($line -split '\|')
            if ($parts.Count -lt 7) { continue }
            $oid = [string]$parts[0]; $state = [string]$parts[1]
            $acceptedT = [DateTime]::ParseExact([string]$parts[2], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv)
            $publishedT = $null; if ($parts[3] -ne "") { $publishedT = [DateTime]::ParseExact([string]$parts[3], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv) }
            $invT = $null; if ($parts[4] -ne "") { $invT = [DateTime]::ParseExact([string]$parts[4], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv) }
            $appliedT = $null; if ($parts[5] -ne "") { $appliedT = [DateTime]::ParseExact([string]$parts[5], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv) }
            $completedT = $null; if ($parts[6] -ne "") { $completedT = [DateTime]::ParseExact([string]$parts[6], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv) }

            # interval in milliseconds, or "" when missing
            $a2p = ""; $p2d = ""; $d2a = ""; $a2c = ""; $a2cTotal = ""
            if ($null -ne $publishedT) { $a2p = [string]([math]::Round(($publishedT - $acceptedT).TotalMilliseconds, 6)); $stageValues.accepted_to_published.Add([double]$a2p) } else { $missing.accepted_to_published++ }
            if ($null -ne $publishedT -and $null -ne $invT) { $p2d = [string]([math]::Round(($invT - $publishedT).TotalMilliseconds, 6)); $stageValues.published_to_decided.Add([double]$p2d) } else { $missing.published_to_decided++ }
            if ($null -ne $invT -and $null -ne $appliedT) { $d2a = [string]([math]::Round(($appliedT - $invT).TotalMilliseconds, 6)); $stageValues.decided_to_applied.Add([double]$d2a) } else { $missing.decided_to_applied++ }
            if ($null -ne $appliedT -and $null -ne $completedT) { $a2c = [string]([math]::Round(($completedT - $appliedT).TotalMilliseconds, 6)); $stageValues.applied_to_completed.Add([double]$a2c) } else { $missing.applied_to_completed++ }
            if ($null -ne $completedT) { $a2cTotal = [string]([math]::Round(($completedT - $acceptedT).TotalMilliseconds, 6)); $stageValues.accepted_to_completed.Add([double]$a2cTotal) } else { $missing.accepted_to_completed++ }
            $csvLines.Add("$oid,$state,$a2p,$p2d,$d2a,$a2c,$a2cTotal")
        }
        [IO.File]::WriteAllLines($intervalsCsvPath, $csvLines.ToArray(), (New-Object Text.UTF8Encoding($false)))

        $stages = [ordered]@{}
        foreach ($k in @("accepted_to_published", "published_to_decided", "decided_to_applied", "applied_to_completed", "accepted_to_completed")) {
            $vals = @($stageValues[$k].ToArray())
            $s = Summarize $vals
            $stages[$k] = [ordered]@{ source = "orders + outbox joins"; p50 = $s.p50; p95 = $s.p95; p99 = $s.p99; negative_count = $s.negative_count; missing_count = $missing[$k] }
        }

        # stock success/rejection rates over unique decisions (Inventory results by type)
        $reserved = SqlInt "SELECT count(DISTINCT io.`"OrderId`") FROM inventory_service.outbox_events io WHERE io.`"EventType`" = 'StockReserved' AND io.`"OrderId`" IN (SELECT `"Id`" FROM order_service.orders WHERE $member);"
        $rejected = SqlInt "SELECT count(DISTINCT io.`"OrderId`") FROM inventory_service.outbox_events io WHERE io.`"EventType`" = 'StockRejected' AND io.`"OrderId`" IN (SELECT `"Id`" FROM order_service.orders WHERE $member);"
        $denom = $reserved + $rejected
        $reservedPct = $null; $rejectedPct = $null
        if ($denom -gt 0) { $reservedPct = $reserved * 100.0 / $denom; $rejectedPct = $rejected * 100.0 / $denom }

        $dbBlock = [ordered]@{
            source = "PostgreSQL (order_service.orders, order_service.outbox_events, inventory_service.outbox_events)"
            run_membership = $membership
            accepted_count = $accepted
            final_state_counts = $stateCounts
            completed_count = $completed
            pending_count = $pending
            stages_ms = $stages
            stock_rates_pct = [ordered]@{ source = "inventory_service.outbox_events"; reserved = $reservedPct; rejected = $rejectedPct; reserved_count = $reserved; rejected_count = $rejected }
        }
        } catch {
            $dbBlockFailed = $true
            $dbFailedReason = "$($_.Exception.Message)"
            if ($dbFailedReason.Length -gt 200) { $dbFailedReason = $dbFailedReason.Substring(0, 200) }
            $dbFailedReason = ($dbFailedReason -replace '[\r\n]+', ' ').Trim()
            $dbBlock = "unavailable (query failed: $dbFailedReason)"
        }
    }
}

# ------------------------------------------------------------------ collector samples
$collectorBlock = "unavailable (no samples.csv)"
$samplesPath = Join-Path $RunDir "samples.csv"
if (Test-Path -LiteralPath $samplesPath) {
    $rows = @(Import-Csv -LiteralPath $samplesPath)
    if ($rows.Count -ge 1) {
        # ---- lookups keyed by time / queue / metric
        $allQueueNames = New-Object System.Collections.Generic.HashSet[string]
        $depthLookup = @{}     # "time|queue" -> ready+unack (only when both numeric)
        $readyMap = @{}; $unackMap = @{}
        $ageMap = @{}          # "time|queue" -> numeric oldest age
        $metricMap = @{}       # "name|labels|time" -> raw string value
        $times = New-Object System.Collections.Generic.List[string]
        $seenTimes = New-Object System.Collections.Generic.HashSet[string]

        foreach ($r in $rows) {
            $t = [string]$r.utc_time
            if (-not $seenTimes.Contains($t)) { $seenTimes.Add($t) | Out-Null; $times.Add($t) }
            $name = [string]$r.name; $labels = [string]$r.labels; $value = [string]$r.value
            $metricMap["$name|$labels|$t"] = $value
            if ($r.source -eq "rabbitmq") {
                $q = LabelValue $labels "queue"
                if ($q -ne "") { [void]$allQueueNames.Add($q) }
                if ($name -eq "messages_ready") { $readyMap["$t|$q"] = Num $value }
                elseif ($name -eq "messages_unacknowledged") { $unackMap["$t|$q"] = Num $value }
                elseif ($name -eq "oldest_age_seconds") { $v = Num $value; if ($null -ne $v) { $ageMap["$t|$q"] = $v } }
            }
        }
        # combine ready + unack into depth, only where both are numeric
        $keySet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($k in $readyMap.Keys) { [void]$keySet.Add([string]$k) }
        foreach ($k in $unackMap.Keys) { [void]$keySet.Add([string]$k) }
        foreach ($k in $keySet) {
            $sk = [string]$k
            if ($readyMap.ContainsKey($sk) -and $unackMap.ContainsKey($sk)) {
                $rd = $readyMap[$sk]; $ud = $unackMap[$sk]
                if ($null -ne $rd -and $null -ne $ud) { $depthLookup[$sk] = ($rd + $ud) }
            }
        }

        # ---- peak queue depth and peak oldest age, per queue
        $peakDepth = [ordered]@{}; $peakAge = [ordered]@{}
        foreach ($q in $allQueueNames) {
            $qPeak = $null; $aPeak = $null
            foreach ($t in $times) {
                $dk = "$t|$q"
                if ($depthLookup.ContainsKey($dk)) { if ($null -eq $qPeak -or $depthLookup[$dk] -gt $qPeak) { $qPeak = $depthLookup[$dk] } }
                if ($ageMap.ContainsKey($dk)) { if ($null -eq $aPeak -or $ageMap[$dk] -gt $aPeak) { $aPeak = $ageMap[$dk] } }
            }
            $peakDepth[$q] = $(if ($null -eq $qPeak) { "unavailable" } else { $qPeak })
            $peakAge[$q] = $(if ($null -eq $aPeak) { "unavailable" } else { $aPeak })
        }

        # ---- counters (reset-aware increase), computed per series then summed.
        #      A "series" is one metric name + full label set (which includes
        #      service=), so a single service restarting only resets its own
        #      counter and is not over-counted against the other services.
        function CategoryIncrease([string[]]$metricNames) {
            $series = [ordered]@{}
            foreach ($r in $rows) {
                if ($r.source -ne "service") { continue }
                if ($metricNames -notcontains [string]$r.name) { continue }
                $v = Num ([string]$r.value)
                if ($null -eq $v) { continue }
                $key = [string]$r.name + "|" + [string]$r.labels
                if (-not $series.Contains($key)) { $series[$key] = New-Object System.Collections.Generic.List[double] }
                $series[$key].Add($v)
            }
            if ($series.Count -eq 0) { return $null }
            $total = 0.0
            foreach ($key in $series.Keys) { $total += CounterIncrease @($series[$key].ToArray()) }
            return $total
        }
        $cRetries = CategoryIncrease @("flashsale_consumer_retries_total")
        $cDups = CategoryIncrease @("flashsale_consumer_duplicates_total")
        $cDlq = CategoryIncrease @("flashsale_consumer_dead_lettered_total", "flashsale_process_worker_dead_lettered_total")
        $cRecon = CategoryIncrease @("flashsale_reconciliation_retriggers_total", "flashsale_reconciliation_given_up_total")

        # ---- host CPU / memory, process CPU / memory, DB connections, broker rates
        function NumericSeries([string]$source, [string]$name, [scriptblock]$filter) {
            $out = @()
            foreach ($r in $rows) {
                if ($r.source -ne $source -or $r.name -ne $name) { continue }
                if ($null -ne $filter -and -not (& $filter $r)) { continue }
                $v = Num ([string]$r.value)
                if ($null -ne $v) { $out += $v }
            }
            return @($out)
        }
        $hostCpu = MeanPeak (NumericSeries "host" "cpu_percent" $null)
        $hostMem = MeanPeak (NumericSeries "host" "memory_used_bytes" $null)
        $dbConnByTime = [ordered]@{}
        foreach ($r in $rows) {
            if ($r.source -ne "postgres" -or $r.name -ne "connections") { continue }
            $v = Num ([string]$r.value); if ($null -eq $v) { continue }
            $t = [string]$r.utc_time
            if (-not $dbConnByTime.Contains($t)) { $dbConnByTime[$t] = 0.0 }
            $dbConnByTime[$t] = $dbConnByTime[$t] + $v
        }
        $dbConn = MeanPeak @($dbConnByTime.Values)
        $pubRate = MeanPeak (NumericSeries "rabbitmq" "publish_rate" $null)
        $delRate = MeanPeak (NumericSeries "rabbitmq" "deliver_get_rate" $null)
        $ackRate = MeanPeak (NumericSeries "rabbitmq" "ack_rate" $null)

        # process CPU (rate of process_cpu_seconds_total, cores) and memory per service
        $procCpu = [ordered]@{}; $procMem = [ordered]@{}
        foreach ($r in $rows) {
            if ($r.source -ne "service") { continue }
            $svc = LabelValue ([string]$r.labels) "service"
            if ($svc -eq "") { continue }
            if ($r.name -eq "process_cpu_seconds_total") {
                if (-not $procCpu.Contains($svc)) { $procCpu[$svc] = New-Object System.Collections.Generic.List[object] }
                $tt = Time ([string]$r.utc_time); $vv = Num ([string]$r.value)
                if ($null -ne $tt -and $null -ne $vv) { $procCpu[$svc].Add(@{ t = $tt; v = $vv }) }
            } elseif ($r.name -eq "process_working_set_bytes") {
                if (-not $procMem.Contains($svc)) { $procMem[$svc] = New-Object System.Collections.Generic.List[double] }
                $vv = Num ([string]$r.value)
                if ($null -ne $vv) { $procMem[$svc].Add($vv) }
            }
        }
        $procCpuOut = [ordered]@{}
        foreach ($svc in $procCpu.Keys) {
            $pts = @($procCpu[$svc] | Sort-Object { $_.t })
            $rates = @()
            for ($i = 1; $i -lt $pts.Count; $i++) {
                $dt = ($pts[$i].t - $pts[$i - 1].t).TotalSeconds
                $dv = $pts[$i].v - $pts[$i - 1].v
                if ($dt -gt 0 -and $dv -ge 0) { $rates += ($dv / $dt) }
            }
            if ($rates.Count -eq 0) { $procCpuOut[$svc] = "unavailable" }
            else { $procCpuOut[$svc] = MeanPeak @($rates) }
        }
        $procMemOut = [ordered]@{}
        foreach ($svc in $procMem.Keys) { $procMemOut[$svc] = MeanPeak @($procMem[$svc].ToArray()) }

        # Redis mean latency = delta(usec) / delta(calls) over the window
        $redisLatency = $null
        $redisCallsByCmd = [ordered]@{}; $redisUsecByCmd = [ordered]@{}
        foreach ($r in $rows) {
            if ($r.source -ne "redis") { continue }
            if ($r.name -ne "calls" -and $r.name -ne "usec") { continue }
            $cmd = LabelValue ([string]$r.labels) "command"
            $v = Num ([string]$r.value)
            if ($null -eq $v -or $cmd -eq "") { continue }
            if ($r.name -eq "calls") {
                if (-not $redisCallsByCmd.Contains($cmd)) { $redisCallsByCmd[$cmd] = New-Object System.Collections.Generic.List[double] }
                $redisCallsByCmd[$cmd].Add($v)
            } else {
                if (-not $redisUsecByCmd.Contains($cmd)) { $redisUsecByCmd[$cmd] = New-Object System.Collections.Generic.List[double] }
                $redisUsecByCmd[$cmd].Add($v)
            }
        }
        $totCalls = 0.0; $totUsec = 0.0
        foreach ($cmd in $redisCallsByCmd.Keys) {
            $cInc = CounterIncrease @($redisCallsByCmd[$cmd].ToArray())
            $totCalls += $cInc
            if ($redisUsecByCmd.Contains($cmd)) { $totUsec += CounterIncrease @($redisUsecByCmd[$cmd].ToArray()) }
        }
        if ($redisCallsByCmd.Count -gt 0 -and $totCalls -gt 0) { $redisLatency = $totUsec / $totCalls }

        # ---- drain time: from the last submission until every queue, both
        #      Outbox gauges and the exact pending-order count are 0. Pending is
        #      read from the database (one query for the whole run), not from the
        #      stuck-orders gauge, which only covers orders past the timeout.
        function GaugeAt([string]$t, [string]$name, [string]$labels) {
            $key = "$name|$labels|$t"
            if ($metricMap.ContainsKey($key)) { return Num $metricMap[$key] }
            return $null
        }
        $drainSeconds = $null
        $drainedTime = $null
        if ($null -ne $lastSubmission -and $allQueueNames.Count -gt 0 -and $dbOk -and -not $dbBlockFailed) {
            # One query for the run: orders accepted inside the run window
            # (From .. last sample), with their acceptance / completion / decision
            # timestamps. The lower bound keeps a stale order left by an earlier
            # run from pinning pending > 0 forever.
            $lastSampleTime = Time (($times | Sort-Object)[-1])
            $pendingLines = @()
            if ($null -ne $lastSampleTime -and $Container -ne "") {
                try {
                    $maxSampleSql = SqlTs $lastSampleTime
                    $fromSqlDrain = SqlTs $windowFrom
                    # Same run membership as the database block when the JTL has keys.
                    $drainMember = "`"RequestAcceptedAt`" >= '$fromSqlDrain' AND `"RequestAcceptedAt`" <= '$maxSampleSql'"
                    if ($safeKeys.Count -gt 0) { $drainMember = $member }
                    $pendingSql = "SELECT to_char(`"RequestAcceptedAt`", 'YYYY-MM-DD HH24:MI:SS.US') || '|' || coalesce(to_char(`"CompletedAt`", 'YYYY-MM-DD HH24:MI:SS.US'), '') || '|' || coalesce(to_char(`"ConfirmedOrRejectedAt`", 'YYYY-MM-DD HH24:MI:SS.US'), '') || '|' || `"State`" FROM order_service.orders WHERE $drainMember;"
                    $pendingLines = @((Sql $pendingSql) -split "`n" | Where-Object { $_ -ne "" })
                } catch {
                    $drainDbFailed = $true
                }
            }
            if (-not $drainDbFailed) {
                $sortedTimes = @($times | Sort-Object)
                foreach ($t in $sortedTimes) {
                $tt = Time $t
                if ($null -eq $tt -or $tt -lt $lastSubmission) { continue }
                $drained = $true
                foreach ($q in $allQueueNames) {
                    $dk = "$t|$q"
                    if (-not $depthLookup.ContainsKey($dk) -or $depthLookup[$dk] -ne 0) { $drained = $false; break }
                }
                if ($drained) {
                    $oPub = GaugeAt $t "flashsale_outbox_unpublished" "service=order-service"
                    $iPub = GaugeAt $t "flashsale_outbox_unpublished" "service=inventory-service"
                    if ($null -ne $oPub -and $null -ne $iPub -and $oPub -eq 0 -and $iPub -eq 0) {
                        # pending = orders accepted by t that are not yet terminal at t
                        # (no CompletedAt <= t, and not a rejection with
                        # ConfirmedOrRejectedAt <= t).
                        $pending = 0
                        foreach ($line in $pendingLines) {
                            $pp = @($line -split '\|')
                            if ($pp.Count -lt 4) { continue }
                            $acc = [DateTime]::ParseExact([string]$pp[0], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv)
                            if ($acc -gt $tt) { continue }
                            $comp = $null; if ($pp[1] -ne "") { $comp = [DateTime]::ParseExact([string]$pp[1], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv) }
                            $appl = $null; if ($pp[2] -ne "") { $appl = [DateTime]::ParseExact([string]$pp[2], 'yyyy-MM-dd HH:mm:ss.ffffff', $inv) }
                            $state = [string]$pp[3]
                            $terminal = $false
                            if ($null -ne $comp -and $comp -le $tt) { $terminal = $true }
                            elseif ($state -eq 'Rejected' -and $null -ne $appl -and $appl -le $tt) { $terminal = $true }
                            if (-not $terminal) { $pending++ }
                        }
                        if ($pending -eq 0) {
                            $drainSeconds = ($tt - $lastSubmission).TotalSeconds
                            $drainedTime = $tt
                        } else { $drained = $false }
                    } else { $drained = $false }
                }
                if ($drained) { break }
            }
            }
        }

        # ---- recovery time (only with -StableRange)
        # From overload removal until the start of the first -StableWindowSeconds
        # window of submissions that is back in the stable range, judged on the
        # requests in that window only:
        #   p95 elapsed, judged on SUCCESSFUL (2xx) submissions only, <=
        #   max_p95_ms (fast 429/503 refusals cannot make latency look good, and
        #   a window with no 2xx is never in range);
        #   internal errors (5xx except 503) <= max_error_pct;
        #   refusals (429 + 503) <= max_refused_pct (when given);
        #   ACCEPTED (2xx) throughput >= min_throughput_per_s;
        #   the window is sustained: every 1-s slot inside it holds at least one
        #   submission (a gap is missing evidence, not stability);
        #   when max_outbox_backlog is given, the Order Outbox gauge at the
        #   window start is at or below it (the backlog has drained); and
        #   when max_total_backlog is given, the total backlog at the window
        #   start (Order Outbox unpublished + Inventory Outbox unpublished +
        #   every main queue's messages_ready + messages_unacknowledged, each
        #   from the latest sample at or before the start, a missing series is
        #   never 0) is at or below it.
        # A phase that refuses everything therefore never counts as recovered.
        # Overload removal is -OverloadEnd, else the first submission whose
        # label matches -RecoveryLabelPattern. No window in range gives
        # "not_recovered"; no recovery phase at all gives "unavailable"; a
        # database failure (probe ok, then a query failed) also gives
        # "unavailable", because recovery cannot be certified while it is down.
        $recovery = "unavailable"
        $recoveryFrom = $null
        $maxP95 = $null; $maxErr = $null; $minTp = $null; $maxRefused = $null; $maxBacklog = $null; $maxTotalBacklog = $null
        $appliedCriteria = [ordered]@{}
        if ($null -ne $StableRange -and $StableRange.Count -gt 0 -and -not $dbBlockFailed) {
            $maxP95 = $StableRange["max_p95_ms"]; $maxErr = $StableRange["max_error_pct"]
            $minTp = $StableRange["min_throughput_per_s"]; $maxRefused = $StableRange["max_refused_pct"]
            $maxBacklog = $StableRange["max_outbox_backlog"]; $maxTotalBacklog = $StableRange["max_total_backlog"]
            if ($null -ne $maxP95) { $appliedCriteria.max_p95_ms = $maxP95 }
            if ($null -ne $maxErr) { $appliedCriteria.max_error_pct = $maxErr }
            if ($null -ne $maxRefused) { $appliedCriteria.max_refused_pct = $maxRefused }
            if ($null -ne $minTp) { $appliedCriteria.min_throughput_per_s = $minTp }
            if ($null -ne $maxBacklog) { $appliedCriteria.max_outbox_backlog = $maxBacklog }
            if ($null -ne $maxTotalBacklog) { $appliedCriteria.max_total_backlog = $maxTotalBacklog }
            if ($OverloadEnd -ne "") {
                $recoveryFrom = [DateTime]::Parse($OverloadEnd, $inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
            } else {
                $firstRecovery = @($subSamples | Where-Object { $_.label -match $RecoveryLabelPattern } | Sort-Object t | Select-Object -First 1)
                if ($firstRecovery.Count -gt 0) { $recoveryFrom = $firstRecovery[0].t }
            }
            $outboxSeries = @(foreach ($r in $rows) {
                if ($r.name -eq "flashsale_outbox_unpublished" -and (HasLabel ([string]$r.labels) "service=order-service")) {
                    $ot = Time ([string]$r.utc_time); $ov = Num ([string]$r.value)
                    if ($null -ne $ot -and $null -ne $ov) { [pscustomobject]@{ t = $ot; v = $ov } }
                }
            }) | Sort-Object t
            $invOutboxSeries = @(foreach ($r in $rows) {
                if ($r.name -eq "flashsale_outbox_unpublished" -and (HasLabel ([string]$r.labels) "service=inventory-service")) {
                    $ot = Time ([string]$r.utc_time); $ov = Num ([string]$r.value)
                    if ($null -ne $ot -and $null -ne $ov) { [pscustomobject]@{ t = $ot; v = $ov } }
                }
            }) | Sort-Object t
            $mainQueueNames = @($allQueueNames | Where-Object { $_ -notlike '*.dlq' } | Sort-Object)
            $queueDepthSeries = @{}
            foreach ($q in $allQueueNames) {
                $pts = @()
                foreach ($tt in ($times | Sort-Object)) {
                    $dk = "$tt|$q"
                    if ($depthLookup.ContainsKey($dk)) { $pts += [pscustomobject]@{ t = (Time $tt); v = $depthLookup[$dk] } }
                }
                $queueDepthSeries[$q] = @($pts)
            }
            if ($null -ne $recoveryFrom) {
                $after = @($subSamples | Where-Object { $_.t -ge $recoveryFrom })
                $recovery = "not_recovered"
                if ($after.Count -gt 0) {
                    $lastAfter = ($after | Sort-Object t)[-1].t
                    $w = [double]$StableWindowSeconds
                    for ($s = 0; $recoveryFrom.AddSeconds($s + $w) -le $lastAfter.AddSeconds(1); $s++) {
                        $ws = $recoveryFrom.AddSeconds($s); $we = $ws.AddSeconds($w)
                        $win = @($after | Where-Object { $_.t -ge $ws -and $_.t -lt $we })
                        if ($win.Count -eq 0) { continue }
                        $ok2xx = @($win | Where-Object { $_.code -match '^2\d\d$' }).Count
                        $refused = @($win | Where-Object { $_.code -eq "429" -or $_.code -eq "503" }).Count
                        $internal = @($win | Where-Object { $_.code -match '^5\d\d$' -and $_.code -ne "503" }).Count
                        $p95w = (Summarize @($win | Where-Object { $_.code -match '^2\d\d$' -and $null -ne $_.elapsed } | ForEach-Object { [double]$_.elapsed })).p95
                        $inRange = $true
                        if ($ok2xx -eq 0) { $inRange = $false }
                        if ($null -ne $maxP95 -and ($null -eq $p95w -or $p95w -gt [double]$maxP95)) { $inRange = $false }
                        if ($null -ne $maxErr -and ($internal * 100.0 / $win.Count) -gt [double]$maxErr) { $inRange = $false }
                        if ($null -ne $maxRefused -and ($refused * 100.0 / $win.Count) -gt [double]$maxRefused) { $inRange = $false }
                        if ($null -ne $minTp -and ($ok2xx / $w) -lt [double]$minTp) { $inRange = $false }
                        if ($inRange) {
                            for ($k = 0; $k -lt [int]$w; $k++) {
                                $slotStart = $ws.AddSeconds($k)
                                if (@($win | Where-Object { $_.t -ge $slotStart -and $_.t -lt $slotStart.AddSeconds(1) }).Count -eq 0) { $inRange = $false; break }
                            }
                        }
                        if ($inRange -and $null -ne $maxBacklog) {
                            $atStart = LastPointAtOrBefore $outboxSeries $ws
                            if ($null -eq $atStart -or $atStart.v -gt [double]$maxBacklog) { $inRange = $false }
                        }
                        if ($inRange -and $null -ne $maxTotalBacklog) {
                            $missingSeries = $false
                            $totalBacklog = 0.0
                            $oPub = LastPointAtOrBefore $outboxSeries $ws
                            $iPub = LastPointAtOrBefore $invOutboxSeries $ws
                            if ($null -eq $oPub -or $null -eq $iPub -or $mainQueueNames.Count -eq 0) { $missingSeries = $true }
                            else {
                                $totalBacklog = [double]$oPub.v + [double]$iPub.v
                                foreach ($q in $mainQueueNames) {
                                    $last = LastPointAtOrBefore $queueDepthSeries[$q] $ws
                                    if ($null -eq $last) { $missingSeries = $true; break }
                                    $totalBacklog += [double]$last.v
                                }
                            }
                            if ($missingSeries -or $totalBacklog -gt [double]$maxTotalBacklog) { $inRange = $false }
                        }
                        if ($inRange) { $recovery = [double]$s; break }
                    }
                }
            }
        }

        $collectorBlock = [ordered]@{
            peak_queue_depth = [ordered]@{ source = "samples.csv (rabbitmq messages_ready + messages_unacknowledged)"; per_queue = $peakDepth }
            peak_oldest_age_seconds = [ordered]@{ source = "samples.csv (rabbitmq oldest_age_seconds)"; per_queue = $peakAge }
            drain_time_s = [ordered]@{ source = "samples.csv (queues + outbox gauges) + DB pending-order count"; value = $(if ($null -eq $drainSeconds) { "unavailable" } else { $drainSeconds }) }
            recovery_time_s = [ordered]@{ source = "raw.jtl $StableWindowSeconds-s windows after overload removal + -StableRange"; overload_removed_utc = $(if ($null -eq $recoveryFrom) { $null } else { $recoveryFrom.ToString("o", $inv) }); window_length_s = $StableWindowSeconds; criteria = $appliedCriteria; value = $recovery }
            counters = [ordered]@{ source = "samples.csv (service flashsale_*_total, reset-aware increase)"; retries = $(if ($null -eq $cRetries) { "unavailable" } else { $cRetries }); duplicates = $(if ($null -eq $cDups) { "unavailable" } else { $cDups }); dead_lettered = $(if ($null -eq $cDlq) { "unavailable" } else { $cDlq }); reconciliation = $(if ($null -eq $cRecon) { "unavailable" } else { $cRecon }) }
            host_cpu_percent = [ordered]@{ source = "samples.csv (host)"; mean = $hostCpu.mean; peak = $hostCpu.peak }
            host_memory_used_bytes = [ordered]@{ source = "samples.csv (host)"; mean = $hostMem.mean; peak = $hostMem.peak }
            process_cpu_rate_cores = [ordered]@{ source = "samples.csv (service process_cpu_seconds_total rate)"; per_service = $procCpuOut }
            process_memory_bytes = [ordered]@{ source = "samples.csv (service process_working_set_bytes)"; per_service = $procMemOut }
            db_connections = [ordered]@{ source = "samples.csv (postgres)"; mean = $dbConn.mean; peak = $dbConn.peak }
            redis_mean_latency_us = [ordered]@{ source = "samples.csv (redis delta(usec)/delta(calls))"; value = $(if ($null -eq $redisLatency) { "unavailable" } else { $redisLatency }) }
            broker_rates = [ordered]@{ source = "samples.csv (rabbitmq)"; publish = $pubRate; deliver_get = $delRate; ack = $ackRate }
        }
    }
}

# ------------------------------------------------------------------ summary.json
$summary = [ordered]@{
    run_id = $RunId
    window_from_utc = $(if ($null -eq $windowFrom) { $null } else { $windowFrom.ToString("o", $inv) })
    window_to_utc = $(if ($null -eq $windowTo) { $null } else { $windowTo.ToString("o", $inv) })
    percentile_method = "nearest-rank"
    jtl = $jtlBlock
    database = $dbBlock
    collector = $collectorBlock
}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8

# ------------------------------------------------------------------ console summary
Write-Output "run=$RunId window=$($summary.window_from_utc)..$($summary.window_to_utc) percentile=nearest-rank"
if ($dbBlock -is [hashtable] -or $dbBlock -is [System.Collections.Specialized.OrderedDictionary]) {
    Write-Output ("DB accepted=" + $dbBlock.accepted_count + " completed=" + $dbBlock.completed_count + " pending=" + $dbBlock.pending_count)
} else {
    Write-Output ("DB " + $dbBlock)
}
if ($collectorBlock -is [System.Collections.Specialized.OrderedDictionary]) {
    Write-Output ("collector drain_time_s=" + $collectorBlock.drain_time_s.value + " recovery_time_s=" + $collectorBlock.recovery_time_s.value + " redis_latency_us=" + $collectorBlock.redis_mean_latency_us.value)
} else {
    Write-Output ("collector " + $collectorBlock)
}
Write-Output "summary=$summaryJsonPath intervals=$intervalsCsvPath"
if ($dbBlockFailed -or $drainDbFailed) { Write-Output "database unavailable: a query failed after the reachability probe"; exit 2 }
exit 0
