# ============================================================
# Week 11 milestone, Task C (TP-P08): extract-run-metrics.ps1 turns a run's raw
# data into the Results-table numbers, with every definition fixed before the
# pilot. This verifier proves the extraction two ways:
#
#   powershell -File .\scripts\verify-extract.ps1 -Container verify-env-pg -DbPort 55432
#
# 1. Known answers, no services. A hand-written JTL (20 submissions, 2 polling
#    rows, one 429 and one 500), a hand-written samples.csv (a queue that rises
#    then drains, two services' retry counters where one resets, an unavailable
#    Redis source) and five seeded orders (one negative publish->decide interval,
#    one missing completion, one completed after the queues are empty) are
#    extracted; every computed value must equal the hand-computed answer, the
#    per-series reset counter, the delayed drain and the negative count included,
#    "unavailable" stays "unavailable", and recovery is "unavailable" without
#    -StableRange.
# 2. A real run. Order/Inventory/Worker run on a throwaway RabbitMQ (5700/15700)
#    and Redis (6410) with the collector running; about 10 orders are placed and
#    extracted; the accepted count equals the orders placed and each order's
#    stage intervals match a direct SQL query.
#
# Negative control: compute a percentile on submissions and polling
# mixed; it must fail the known-answer checks.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 35     # number of Check calls in the try block (a truncated run must fail)

# real-run stack (Part 2)
$mq = "verify-ex-mq"; $amqp = 5700; $mgmt = 15700; $redis = "verify-ex-redis"; $redisPort = 6410
$orderPort = 5160; $invPort = 5161; $workerPort = 5162
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessingStarted.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"

# ------------------------------------------------------------------ helpers
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql) {
    $v = Sql $sql
    if ($v -eq "") { return -1 }
    return [int]$v
}
# AsNum returns a double, or $null when the value is missing or "unavailable".
# Every numeric comparison goes through it so a legitimate "unavailable" fails
# one check instead of throwing and aborting the rest of the run.
function AsNum($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [string] -and $v -eq "unavailable") { return $null }
    try { return [double]$v } catch { return $null }
}
function Near($a, $b, [double]$eps = 0.001) {
    $av = AsNum $a; $bv = AsNum $b
    if ($null -eq $av -or $null -eq $bv) { return $false }
    return ([math]::Abs($av - $bv) -le $eps)
}
function Eq($v, $expected) {
    $av = AsNum $v
    if ($null -eq $av) { return $false }
    return ($av -eq $expected)
}
function IsUnavailable($v) { return ($v -is [string] -and $v -eq "unavailable") }
function Seed([string]$id, [string]$state, [string]$accepted, [string]$published, [string]$invCreated, [string]$applied, [string]$completed, [string]$invType) {
    $appliedSql = $(if ($applied -eq "") { "NULL" } else { "'$applied'" })
    $completedSql = $(if ($completed -eq "") { "NULL" } else { "'$completed'" })
    $o = "INSERT INTO order_service.orders (`"Id`", `"IdempotencyKey`", `"ProductId`", `"Quantity`", `"State`", `"CorrelationId`", `"RequestAcceptedAt`", `"ConfirmedOrRejectedAt`", `"CompletedAt`") VALUES ('$id', 'ek-$id', 'known-product', 1, '$state', 'extract-known-answers', '$accepted', $appliedSql, $completedSql);"
    Sql $o | Out-Null
    $op = "INSERT INTO order_service.outbox_events (`"Id`", `"OrderId`", `"EventType`", `"Payload`", `"Published`", `"CreatedAt`", `"PublishedAt`") VALUES ('$([guid]::NewGuid())', '$id', 'OrderPlaced', '{}'::jsonb, true, '$accepted', '$published');"
    Sql $op | Out-Null
    $io = "INSERT INTO inventory_service.outbox_events (`"Id`", `"OrderId`", `"EventType`", `"Payload`", `"Published`", `"CreatedAt`", `"PublishedAt`") VALUES ('$([guid]::NewGuid())', '$id', '$invType', '{}'::jsonb, true, '$invCreated', '$invCreated');"
    Sql $io | Out-Null
}
function Cleanup-Seeded([string[]]$ids) {
    foreach ($id in $ids) {
        Sql "DELETE FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id';" | Out-Null
        Sql "DELETE FROM order_service.outbox_events WHERE `"OrderId`" = '$id';" | Out-Null
        Sql "DELETE FROM order_service.orders WHERE `"Id`" = '$id';" | Out-Null
    }
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 20 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function QueueExists([string]$q) { return ($null -ne (Mq Get "/queues/%2F/$q")) }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis([string[]]$cmd) { return (docker exec $redis redis-cli @cmd | Out-String).Trim() }
function Stock([string]$product) { return (Redis "GET", "inventory:$product") }
function Log([string]$project) {
    if (-not $logs[$project]) { return "" }
    if (-not (Test-Path -LiteralPath $logs[$project])) { return "" }
    $fs = New-Object IO.FileStream($logs[$project], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Running([string]$project) { return @(Get-CimInstance Win32_Process -Filter "Name='$project.exe'").Count -gt 0 }
function Stop-Svc([string]$project) {
    Get-CimInstance Win32_Process -Filter "Name='$project.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Wait-Until { -not (Running $project) } 20 | Out-Null
}
function Start-Svc([string]$project, [string]$tag) {
    $envs = @{} + $svcEnv[$project]
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-ex-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "ex-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }

# ------------------------------------------------------------------ run
try {
    # ---------------------------------------------------------- guards
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable; this verifier needs Docker" }
    if ((Int1 "SELECT 1;") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5160-5162" }
    }

    # ============================================================ Part 1: known answers
    Write-Output "== Part 1: known answers (no services)"
    $runDir = Join-Path $env:TEMP "verify-extract-known-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $jtlPath = Join-Path $runDir "raw.jtl"
    $samplesPath = Join-Path $runDir "samples.csv"
    $from = "2026-01-01T00:00:00Z"; $to = "2026-01-01T00:00:10Z"
    $base = [DateTimeOffset]::Parse($from).ToUnixTimeMilliseconds()

    # ---- hand-written JTL: 20 submissions (elapsed 10..200), 2 polling rows
    $jtlHeader = "timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,failureMessage,bytes,sentBytes,grpThreads,allThreads,URL,Latency,IdleTime,Connect"
    $jtlLines = New-Object System.Collections.Generic.List[string]
    $jtlLines.Add($jtlHeader)
    for ($i = 0; $i -lt 20; $i++) {
        $ts = $base + ($i * 100)
        $elapsed = 10 * ($i + 1)
        $code = "200"
        if ($i -eq 0) { $code = "429" } elseif ($i -eq 1) { $code = "500" }
        $jtlLines.Add("$ts,$elapsed,submit-order,$code,OK,Thread Group 1-1,text,true,,0,0,1,1,http://localhost:5100/api/orders,0,0,0")
    }
    foreach ($pe in @(50, 70)) {
        $ts = $base + 2000 + (($pe - 50) * 2)   # 50 -> 2000, 70 -> 2040 (both in-window; timestamps do not affect the checks)
        $jtlLines.Add("$ts,$pe,poll-order,200,OK,Thread Group 1-1,text,true,,0,0,1,1,http://localhost:5100/api/orders,0,0,0")
    }
    [IO.File]::WriteAllLines($jtlPath, $jtlLines.ToArray(), (New-Object Text.UTF8Encoding($false)))

    # ---- hand-written samples.csv (5 sample times, 1 s apart)
    $t = @("2026-01-01T00:00:20.000Z", "2026-01-01T00:00:21.000Z", "2026-01-01T00:00:22.000Z", "2026-01-01T00:00:23.000Z", "2026-01-01T00:00:24.000Z")
    $csv = New-Object System.Collections.Generic.List[string]
    $csv.Add("utc_time,source,name,labels,value")
    function Row([string]$time, [string]$source, [string]$name, [string]$labels, [string]$value) { $script:csv.Add("$time,$source,$name,$labels,$value") }
    $ready = @(5, 3, 0, 0, 0); $age = @(4, 2, 0, 0, 0)
    $retriesA = @(3, 5, 0, 2, 2); $retriesB = @(10, 12, 14, 15, 15); $dups = @(0, 1, 1, 2, 2)
    $reTrig = @(0, 0, 1, 1, 1); $cpu = @(10, 20, 30, 40, 50)
    $mem = @(1000, 1100, 1200, 1300, 1400); $pcpu = @(100, 101, 102, 103, 104)
    $pmem = @(5000000, 5100000, 5200000, 5300000, 5400000)
    $conn = @(1, 2, 2, 3, 1); $pub = @(100, 120, 80, 90, 110); $rate = @(50, 60, 40, 45, 55)
    for ($i = 0; $i -lt 5; $i++) {
        $tt = $t[$i]
        Row $tt "rabbitmq" "messages_ready" "queue=OrderPlaced" "$($ready[$i])"
        Row $tt "rabbitmq" "messages_unacknowledged" "queue=OrderPlaced" "0"
        Row $tt "rabbitmq" "oldest_age_seconds" "queue=OrderPlaced" "$($age[$i])"
        Row $tt "service" "flashsale_consumer_retries_total" "service=order-service;consumer=StockResult" "$($retriesB[$i])"
        Row $tt "service" "flashsale_consumer_retries_total" "service=inventory-service;consumer=OrderPlaced" "$($retriesA[$i])"
        Row $tt "service" "flashsale_consumer_duplicates_total" "service=order-service;consumer=StockResult" "$($dups[$i])"
        Row $tt "service" "flashsale_consumer_dead_lettered_total" "service=order-service;consumer=StockResult;reason=exhausted" "0"
        Row $tt "service" "flashsale_reconciliation_retriggers_total" "service=order-service" "$($reTrig[$i])"
        Row $tt "service" "flashsale_reconciliation_given_up_total" "service=order-service" "0"
        Row $tt "service" "flashsale_outbox_unpublished" "service=order-service" "0"
        Row $tt "service" "flashsale_outbox_unpublished" "service=inventory-service" "0"
        Row $tt "service" "flashsale_reconciliation_stuck_orders" "service=order-service" "0"
        Row $tt "host" "cpu_percent" "" "$($cpu[$i])"
        Row $tt "host" "memory_used_bytes" "" "$($mem[$i])"
        Row $tt "service" "process_cpu_seconds_total" "service=order-service" "$($pcpu[$i])"
        Row $tt "service" "process_working_set_bytes" "service=order-service" "$($pmem[$i])"
        Row $tt "postgres" "connections" "usename=order_service_user" "$($conn[$i])"
        Row $tt "rabbitmq" "publish_rate" "" "$($pub[$i])"
        Row $tt "rabbitmq" "deliver_get_rate" "" "$($rate[$i])"
        Row $tt "rabbitmq" "ack_rate" "" "$($rate[$i])"
    }
    # one unavailable source: Redis is down for the whole window
    Row $t[0] "redis" "unavailable" "error=redis down" "unavailable"
    [IO.File]::WriteAllLines($samplesPath, $csv.ToArray(), (New-Object Text.UTF8Encoding($false)))

    # ---- five seeded orders with known timestamps. The third order completes at
    #      00:00:22.500, after the queues empty at 00:00:22, so it delays the
    #      drain point to the 00:00:23 sample (R3). The fifth (Rejected) has no
    #      completion, the one missing-completion case.
    $seed = @()
    $seed += @{ id = [guid]::NewGuid().ToString(); state = "Completed"; accepted = "2026-01-01 00:00:01.000000"; published = "2026-01-01 00:00:01.100000"; inv = "2026-01-01 00:00:01.150000"; applied = "2026-01-01 00:00:01.200000"; completed = "2026-01-01 00:00:02.000000"; type = "StockReserved" }
    $seed += @{ id = [guid]::NewGuid().ToString(); state = "Completed"; accepted = "2026-01-01 00:00:02.000000"; published = "2026-01-01 00:00:02.500000"; inv = "2026-01-01 00:00:02.400000"; applied = "2026-01-01 00:00:02.600000"; completed = "2026-01-01 00:00:03.500000"; type = "StockReserved" }
    $seed += @{ id = [guid]::NewGuid().ToString(); state = "Completed"; accepted = "2026-01-01 00:00:04.000000"; published = "2026-01-01 00:00:04.200000"; inv = "2026-01-01 00:00:04.300000"; applied = "2026-01-01 00:00:04.400000"; completed = "2026-01-01 00:00:22.500000"; type = "StockReserved" }
    $seed += @{ id = [guid]::NewGuid().ToString(); state = "Completed"; accepted = "2026-01-01 00:00:05.000000"; published = "2026-01-01 00:00:05.100000"; inv = "2026-01-01 00:00:05.200000"; applied = "2026-01-01 00:00:05.300000"; completed = "2026-01-01 00:00:06.000000"; type = "StockReserved" }
    $seed += @{ id = [guid]::NewGuid().ToString(); state = "Rejected"; accepted = "2026-01-01 00:00:06.000000"; published = "2026-01-01 00:00:06.100000"; inv = "2026-01-01 00:00:06.200000"; applied = "2026-01-01 00:00:06.300000"; completed = ""; type = "StockRejected" }
    foreach ($s in $seed) { Seed $s.id $s.state $s.accepted $s.published $s.inv $s.applied $s.completed $s.type }
    # ---- a stale order accepted BEFORE the window that never completes: it must
    #      not count as pending (drain stays 21.1 s) and must not appear in
    #      accepted_count or the stage intervals (R5).
    $staleId = [guid]::NewGuid().ToString()
    Sql "INSERT INTO order_service.orders (`"Id`", `"IdempotencyKey`", `"ProductId`", `"Quantity`", `"State`", `"CorrelationId`", `"RequestAcceptedAt`", `"ConfirmedOrRejectedAt`", `"CompletedAt`") VALUES ('$staleId', 'ek-$staleId', 'stale-product', 1, 'PendingStock', 'extract-known-answers', '2025-12-31 23:59:59.000000', NULL, NULL);" | Out-Null
    $cleanupIds = @($seed | ForEach-Object { $_.id })
    $cleanupIds += $staleId

    # ---- run the extraction
    $extract = Join-Path $repoRoot "scripts\extract-run-metrics.ps1"
    $out = & powershell -NoProfile -File $extract -RunId "known" -RunDir $runDir -JtlPath $jtlPath -From $from -To $to -Container $Container 2>&1
    $extractExit = $LASTEXITCODE
    $summaryPath = Join-Path $runDir "summary.json"
    $intervalsPath = Join-Path $runDir "stage-intervals.csv"
    Check "extract ran (exit 0) and wrote summary.json + stage-intervals.csv" ($extractExit -eq 0 -and (Test-Path -LiteralPath $summaryPath) -and (Test-Path -LiteralPath $intervalsPath)) "exit=$extractExit"

    $sum = $null
    if (Test-Path -LiteralPath $summaryPath) { try { $sum = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json } catch { } }
    Check "summary.json parses" ($null -ne $sum)

    # ---- window / JTL checks
    Check "window_from_utc equals the first JTL sample (no local-zone shift)" ($sum.window_from_utc -eq "2026-01-01T00:00:00.0000000Z") "got=$($sum.window_from_utc)"
    Check "JTL: submission_count = 20" (Eq $sum.jtl.submission_count 20) "got=$($sum.jtl.submission_count)"
    Check "JTL: submission p50/p95/p99/max = 100/190/200/200" (Eq $sum.jtl.submission_elapsed_ms.p50 100 -and Eq $sum.jtl.submission_elapsed_ms.p95 190 -and Eq $sum.jtl.submission_elapsed_ms.p99 200 -and Eq $sum.jtl.submission_elapsed_ms.max 200) "p50=$($sum.jtl.submission_elapsed_ms.p50) p95=$($sum.jtl.submission_elapsed_ms.p95) p99=$($sum.jtl.submission_elapsed_ms.p99) max=$($sum.jtl.submission_elapsed_ms.max)"
    Check "JTL: polling_count = 2, polling p50/p95/p99/max = 50/70/70/70" (Eq $sum.jtl.polling_count 2 -and Eq $sum.jtl.polling_elapsed_ms.p50 50 -and Eq $sum.jtl.polling_elapsed_ms.p95 70 -and Eq $sum.jtl.polling_elapsed_ms.p99 70 -and Eq $sum.jtl.polling_elapsed_ms.max 70) "poll_count=$($sum.jtl.polling_count)"
    Check "JTL: offered throughput = 2.0/s" (Near $sum.jtl.offered_throughput_per_s 2.0) "got=$($sum.jtl.offered_throughput_per_s)"
    Check "JTL: overload rejection (429) = 5.0%, internal error (500) = 5.0%, other non-2xx = 0.0%" (Near $sum.jtl.overload_rejection_pct 5.0 -and Near $sum.jtl.internal_error_pct 5.0 -and Near $sum.jtl.other_non_2xx_pct 0.0) "overload=$($sum.jtl.overload_rejection_pct) err=$($sum.jtl.internal_error_pct) other=$($sum.jtl.other_non_2xx_pct)"

    # ---- database checks
    Check "DB: accepted_count = 5" (Eq $sum.database.accepted_count 5) "got=$($sum.database.accepted_count)"
    Check "DB: completed_count = 4, pending_count = 0" (Eq $sum.database.completed_count 4 -and Eq $sum.database.pending_count 0) "completed=$($sum.database.completed_count) pending=$($sum.database.pending_count)"
    Check "DB: final states Completed=4 Rejected=1" (Eq $sum.database.final_state_counts.Completed 4 -and Eq $sum.database.final_state_counts.Rejected 1) "Completed=$($sum.database.final_state_counts.Completed) Rejected=$($sum.database.final_state_counts.Rejected)"
    Check "DB: accepted_to_published p50/p95/p99=100/500/500 neg=0 missing=0" (Near $sum.database.stages_ms.accepted_to_published.p50 100 -and Near $sum.database.stages_ms.accepted_to_published.p95 500 -and Near $sum.database.stages_ms.accepted_to_published.p99 500 -and Eq $sum.database.stages_ms.accepted_to_published.negative_count 0 -and Eq $sum.database.stages_ms.accepted_to_published.missing_count 0) "p50=$($sum.database.stages_ms.accepted_to_published.p50) p95=$($sum.database.stages_ms.accepted_to_published.p95)"
    Check "DB: published_to_decided p50/p95/p99=100/100/100 neg=1 missing=0" (Near $sum.database.stages_ms.published_to_decided.p50 100 -and Near $sum.database.stages_ms.published_to_decided.p95 100 -and Near $sum.database.stages_ms.published_to_decided.p99 100 -and Eq $sum.database.stages_ms.published_to_decided.negative_count 1 -and Eq $sum.database.stages_ms.published_to_decided.missing_count 0) "neg=$($sum.database.stages_ms.published_to_decided.negative_count) p50=$($sum.database.stages_ms.published_to_decided.p50)"
    Check "DB: decided_to_applied p50/p95/p99=100/200/200 neg=0 missing=0" (Near $sum.database.stages_ms.decided_to_applied.p50 100 -and Near $sum.database.stages_ms.decided_to_applied.p95 200 -and Near $sum.database.stages_ms.decided_to_applied.p99 200 -and Eq $sum.database.stages_ms.decided_to_applied.negative_count 0 -and Eq $sum.database.stages_ms.decided_to_applied.missing_count 0) "p50=$($sum.database.stages_ms.decided_to_applied.p50) p95=$($sum.database.stages_ms.decided_to_applied.p95)"
    Check "DB: applied_to_completed p50/p95/p99=800/18100/18100 neg=0 missing=1" (Near $sum.database.stages_ms.applied_to_completed.p50 800 -and Near $sum.database.stages_ms.applied_to_completed.p95 18100 -and Near $sum.database.stages_ms.applied_to_completed.p99 18100 -and Eq $sum.database.stages_ms.applied_to_completed.negative_count 0 -and Eq $sum.database.stages_ms.applied_to_completed.missing_count 1) "missing=$($sum.database.stages_ms.applied_to_completed.missing_count)"
    Check "DB: accepted_to_completed p50/p95/p99=1000/18500/18500 neg=0 missing=1" (Near $sum.database.stages_ms.accepted_to_completed.p50 1000 -and Near $sum.database.stages_ms.accepted_to_completed.p95 18500 -and Near $sum.database.stages_ms.accepted_to_completed.p99 18500 -and Eq $sum.database.stages_ms.accepted_to_completed.negative_count 0 -and Eq $sum.database.stages_ms.accepted_to_completed.missing_count 1) "missing=$($sum.database.stages_ms.accepted_to_completed.missing_count)"
    Check "DB: stock rates reserved=80.0% rejected=20.0% (4 reserved, 1 rejected)" (Near $sum.database.stock_rates_pct.reserved 80.0 -and Near $sum.database.stock_rates_pct.rejected 20.0 -and Eq $sum.database.stock_rates_pct.reserved_count 4 -and Eq $sum.database.stock_rates_pct.rejected_count 1) "reserved=$($sum.database.stock_rates_pct.reserved) rejected=$($sum.database.stock_rates_pct.rejected)"

    # ---- stage-intervals.csv checks
    $csvRows = @()
    if (Test-Path -LiteralPath $intervalsPath) { $csvRows = @(Import-Csv -LiteralPath $intervalsPath) }
    $negRow = @($csvRows | Where-Object { (AsNum $_.published_to_decided_ms) -lt 0 })
    $missingRow = @($csvRows | Where-Object { $_.applied_to_completed_ms -eq "" })
    Check "stage-intervals.csv has 5 rows, one negative publish_to_decided, one missing completion" ($csvRows.Count -eq 5 -and $negRow.Count -eq 1 -and $missingRow.Count -eq 1) "rows=$($csvRows.Count) negative=$($negRow.Count) missing-completion=$($missingRow.Count)"

    # ---- collector checks
    Check "collector: peak queue depth OrderPlaced = 5" (Near $sum.collector.peak_queue_depth.per_queue.OrderPlaced 5.0) "got=$($sum.collector.peak_queue_depth.per_queue.OrderPlaced)"
    Check "collector: peak oldest age OrderPlaced = 4" (Near $sum.collector.peak_oldest_age_seconds.per_queue.OrderPlaced 4.0) "got=$($sum.collector.peak_oldest_age_seconds.per_queue.OrderPlaced)"
    Check "collector: drain time = 21.1s (late-completing order delays it past the empty queues)" (Near $sum.collector.drain_time_s.value 21.1 0.01) "got=$($sum.collector.drain_time_s.value)"
    Check "collector: recovery time is unavailable without -StableRange" (IsUnavailable $sum.collector.recovery_time_s.value) "got=$($sum.collector.recovery_time_s.value)"
    Check "collector: counters retries=9 duplicates=2 dead_lettered=0 reconciliation=1 (per-series reset)" (Near $sum.collector.counters.retries 9 -and Near $sum.collector.counters.duplicates 2 -and Near $sum.collector.counters.dead_lettered 0 -and Near $sum.collector.counters.reconciliation 1) "retries=$($sum.collector.counters.retries) dups=$($sum.collector.counters.duplicates) dlq=$($sum.collector.counters.dead_lettered) recon=$($sum.collector.counters.reconciliation)"
    Check "collector: host cpu mean/peak=30/50, memory mean/peak=1200/1400" (Near $sum.collector.host_cpu_percent.mean 30.0 -and Near $sum.collector.host_cpu_percent.peak 50.0 -and Near $sum.collector.host_memory_used_bytes.mean 1200.0 -and Near $sum.collector.host_memory_used_bytes.peak 1400.0) "cpu=$($sum.collector.host_cpu_percent.mean)/$($sum.collector.host_cpu_percent.peak) mem=$($sum.collector.host_memory_used_bytes.mean)/$($sum.collector.host_memory_used_bytes.peak)"
    Check "collector: process cpu rate order-service mean/peak=1.0/1.0" (Near $sum.collector.process_cpu_rate_cores.per_service.'order-service'.mean 1.0 -and Near $sum.collector.process_cpu_rate_cores.per_service.'order-service'.peak 1.0) "got=$($sum.collector.process_cpu_rate_cores.per_service.'order-service'.mean)/$($sum.collector.process_cpu_rate_cores.per_service.'order-service'.peak)"
    Check "collector: process memory order-service mean/peak=5200000/5400000" (Near $sum.collector.process_memory_bytes.per_service.'order-service'.mean 5200000.0 -and Near $sum.collector.process_memory_bytes.per_service.'order-service'.peak 5400000.0) "got=$($sum.collector.process_memory_bytes.per_service.'order-service'.mean)/$($sum.collector.process_memory_bytes.per_service.'order-service'.peak)"
    Check "collector: db connections mean/peak=1.8/3.0" (Near $sum.collector.db_connections.mean 1.8 0.0001 -and Near $sum.collector.db_connections.peak 3.0) "got=$($sum.collector.db_connections.mean)/$($sum.collector.db_connections.peak)"
    Check "collector: redis latency stays unavailable" (IsUnavailable $sum.collector.redis_mean_latency_us.value) "got=$($sum.collector.redis_mean_latency_us.value)"
    Check "collector: broker rates publish=100/120 deliver=50/60 ack=50/60" (Near $sum.collector.broker_rates.publish.mean 100.0 -and Near $sum.collector.broker_rates.publish.peak 120.0 -and Near $sum.collector.broker_rates.deliver_get.mean 50.0 -and Near $sum.collector.broker_rates.deliver_get.peak 60.0 -and Near $sum.collector.broker_rates.ack.mean 50.0 -and Near $sum.collector.broker_rates.ack.peak 60.0) "pub=$($sum.collector.broker_rates.publish.mean)/$($sum.collector.broker_rates.publish.peak)"

    Cleanup-Seeded $cleanupIds

    # ============================================================ Part 2: real run
    Write-Output "== Part 2: real run (services + collector)"
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-ex-definitions.json"; $conf = Join-Path $env:TEMP "verify-ex-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $hash = [Convert]::ToBase64String($salt + [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev")))
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(
            @{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} }
            @{ name = $dlx; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    Start-Svc "FlashSale.OrderService" "start"
    Start-Svc "FlashSale.InventoryService" "start"
    Start-Svc "FlashSale.ProcessWorker" "start"
    $all = $allQueues + $allDlqs
    $ready = Wait-Until { @($all | Where-Object { -not (QueueExists $_) }).Count -eq 0 } 120
    Check "real run: three services up; every queue and DLQ declared" $ready (($all | ForEach-Object { "$_=$(QueueExists $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    $runId = "ex-" + (Get-Date).ToUniversalTime().ToString("HHmmss")
    $product = "ex-$runId"
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $product = 20 } -Force *> $null
    Check "real run: warm-up $product has 20 units" ((Stock $product) -eq "20")

    # start the collector, then place ~10 orders
    $runDir2 = Join-Path $env:TEMP "verify-ex-$runId"
    New-Item -ItemType Directory -Force -Path $runDir2 | Out-Null
    $collector = Join-Path $repoRoot "scripts\collect-run-metrics.ps1"
    $cproc = Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile", "-File", $collector,
        "-RunId", $runId, "-OutDir", $runDir2, "-IntervalSeconds", "5", "-DurationSeconds", "45",
        "-RabbitMqUrl", "http://localhost:$mgmt", "-RedisContainer", $redis, "-PostgresContainer", $Container,
        "-OrderMetricsUrl", "http://localhost:$orderPort/metrics",
        "-InventoryMetricsUrl", "http://localhost:$invPort/metrics",
        "-WorkerMetricsUrl", "http://localhost:$workerPort/metrics"
    ) -RedirectStandardOutput (Join-Path $runDir2 "collector.out.log") -RedirectStandardError (Join-Path $runDir2 "collector.err.log") -WindowStyle Hidden -PassThru
    $collectorStarted = Wait-Until { Test-Path -LiteralPath (Join-Path $runDir2 "collector.json") } 30
    Check "real run: collector started" $collectorStarted

    $runFrom = [DateTime]::UtcNow
    $placedIds = @(); $placed = 0
    for ($i = 0; $i -lt 10; $i++) { $id = Post-Order $product ("ex-real-$i-" + [guid]::NewGuid()); if ($id) { $placedIds += $id; $placed++ } }
    $allDone = Wait-Until { $ok = $true; foreach ($id in $placedIds) { if ((State $id) -ne "Completed") { $ok = $false } }; return $ok } 120
    $runTo = [DateTime]::UtcNow
    Check "real run: 10 orders placed and all reached Completed" ($placed -eq 10 -and $allDone) "placed=$placed allDone=$allDone"

    # wait for the collector to finish, then extract
    for ($i = 0; $i -lt 70; $i++) { $cproc.Refresh(); if ($cproc.HasExited) { break }; Start-Sleep 1 }

    $out2 = & powershell -NoProfile -File $extract -RunId $runId -RunDir $runDir2 -From $runFrom.ToString("o") -To $runTo.ToString("o") -Container $Container 2>&1
    $extractExit2 = $LASTEXITCODE
    $sum2 = $null
    $summaryPath2 = Join-Path $runDir2 "summary.json"
    if (Test-Path -LiteralPath $summaryPath2) { try { $sum2 = Get-Content -LiteralPath $summaryPath2 -Raw | ConvertFrom-Json } catch { } }
    Check "real run: extract ran and accepted_count = 10" ($extractExit2 -eq 0 -and $null -ne $sum2 -and (Eq $sum2.database.accepted_count $placed)) "exit=$extractExit2 accepted=$($sum2.database.accepted_count)"

    # cross-check each order's stage intervals against a direct SQL query
    $intervalsPath2 = Join-Path $runDir2 "stage-intervals.csv"
    $ivRows = @{}
    if (Test-Path -LiteralPath $intervalsPath2) {
        foreach ($r in @(Import-Csv -LiteralPath $intervalsPath2)) { $ivRows[[string]$r.order_id] = $r }
    }
    $ivOk = $true; $ivDetail = ""
    foreach ($id in $placedIds) {
        $sql = @"
SELECT coalesce(round((extract(epoch from (op."PublishedAt" - o."RequestAcceptedAt"))*1000)::numeric, 6)::text, '') || '|' ||
       coalesce(round((extract(epoch from (io."CreatedAt" - op."PublishedAt"))*1000)::numeric, 6)::text, '') || '|' ||
       coalesce(round((extract(epoch from (o."ConfirmedOrRejectedAt" - io."CreatedAt"))*1000)::numeric, 6)::text, '') || '|' ||
       coalesce(round((extract(epoch from (o."CompletedAt" - o."ConfirmedOrRejectedAt"))*1000)::numeric, 6)::text, '') || '|' ||
       coalesce(round((extract(epoch from (o."CompletedAt" - o."RequestAcceptedAt"))*1000)::numeric, 6)::text, '')
FROM order_service.orders o
LEFT JOIN order_service.outbox_events op ON op."OrderId" = o."Id" AND op."EventType" = 'OrderPlaced'
LEFT JOIN inventory_service.outbox_events io ON io."OrderId" = o."Id"
WHERE o."Id" = '$id';
"@
        $direct = (Sql $sql)
        $directParts = @($direct -split '\|')
        $row = $ivRows[$id]
        if ($null -eq $row -or $directParts.Count -lt 5) { $ivOk = $false; $ivDetail = "order $id missing in CSV"; break }
        $csvParts = @($row.accepted_to_published_ms, $row.published_to_decided_ms, $row.decided_to_applied_ms, $row.applied_to_completed_ms, $row.accepted_to_completed_ms)
        for ($k = 0; $k -lt 5; $k++) {
            $a = 0.0; $b = 0.0
            $aStr = [string]$csvParts[$k]; $bStr = [string]$directParts[$k]
            if ($aStr -eq "" -and $bStr -eq "") { continue }
            if ($aStr -eq "" -or $bStr -eq "") { $ivOk = $false; $ivDetail = "order $id col $k present/absent mismatch ($aStr vs $bStr)"; break }
            $a = [double]$aStr; $b = [double]$bStr
            if (-not (Near $a $b 0.01)) { $ivOk = $false; $ivDetail = "order $id col ${k}: csv=$a sql=$b"; break }
        }
        if (-not $ivOk) { break }
    }
    Check "real run: each order's stage intervals match a direct SQL query" $ivOk $ivDetail
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    if ($cproc -and -not $cproc.HasExited) { Stop-Process -Id $cproc.Id -Force -ErrorAction SilentlyContinue }
    foreach ($project in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $project }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
    Cleanup-Seeded $cleanupIds
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: the extraction reproduces the known answers and a real run's orders."
exit 0
