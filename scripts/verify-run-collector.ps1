# ============================================================
# Week 11 milestone, Task B (TP-P07): the run-time collector samples every
# source during a run, and a failing source is recorded as "unavailable"
# (never 0) while the other sources keep sampling.
#
#   powershell -File .\scripts\verify-run-collector.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5698/15698, collect_statistics_interval 1 s) and Redis (6405)
# against the given PostgreSQL container. Services run on ports 5156 (Order),
# 5157 (Inventory) and 5158 (Worker). It then starts scripts\collect-run-metrics.ps1
# for ~45 s at a 5 s interval (the collector's default) and, while it runs:
# places a few orders with everything up, stops Inventory so OrderPlaced backs
# up, and stops Redis so the redis rows become "unavailable" while the other
# sources keep coming. Each stop window spans at least two samples.
#
# Checks:
#   setup : services up, warm-up, the collector started (collector.json).
#   CSV   : rows from every source; OrderPlaced messages_ready peak >= 1 and
#           oldest_age_seconds > 0 while Inventory was stopped; Redis calls rose;
#           connections >= 1 per service account; host CPU and memory present;
#           accepted counter rose by the number of orders placed; the mean
#           sample gap is <= interval + 1 s; every main queue has messages_ready
#           rows; redis rows became "unavailable" while Redis was stopped and the
#           other sources kept sampling; collector.json records run id, interval
#           and commit.
#
# It then checks the EC2-only container-mode paths on a second throwaway broker
# (verify-rc-mq2) started WITHOUT a published management port (only amqp 5699):
# the collector run with -RabbitMqContainer (messages_ready peak >= 1 on a queue
# holding a message; the three rate rows "unavailable" with reason=no management
# API in container mode; collector.json mode=container; no flashsale_dev or
# RABBITMQ_PASSWORD value leaks into collector.json/samples.csv), and
# set-queue-bounds.ps1 applying/removing the policy with rabbitmqctl (no
# credentials, no port). It confirms the management-API path still works on the
# main broker, which does publish 15672 (verify-load-shedding.ps1 covers it too).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 26     # number of Check calls in the try block (a truncated run must fail)
$mq = "verify-rc-mq"; $amqp = 5698; $mgmt = 15698; $redis = "verify-rc-redis"; $redisPort = 6405
$mq2 = "verify-rc-mq2"; $amqp2 = 5699
$orderPort = 5156; $invPort = 5157; $workerPort = 5158
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__Enabled = "false" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}   # project -> current log file
$runId = "rc-" + (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "rc-$runId"                     # warmed product
$initialStock = 50
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessingStarted.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"
$collectorInterval = 5   # the -IntervalSeconds the collector is started with (its default)
$collectorDuration = 45  # ~9 samples at a 5 s interval

# ------------------------------------------------------------------ helpers
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    # Count BEFORE any output, and write to the output stream (not the host),
    # so a broken console can never turn a failure into a pass.
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}
function Sql([string]$sql, [string]$user = "flashsale") {
    $out = $sql | docker exec -i $Container psql -U $user -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql, [string]$user = "flashsale") {
    $v = Sql $sql $user
    if ($v -eq "") { return -1 }
    return [int]$v
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 20 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function QueueDepth([string]$q) {
    $line = docker exec $mq rabbitmqctl -q list_queues name messages --no-table-headers 2>$null | Where-Object { ($_ -split "`t")[0] -eq $q }
    if ($line) { return [int](($line -split "`t")[1]) } else { return -1 }
}
function QueueExists([string]$q) { return ($null -ne (Mq Get "/queues/%2F/$q")) }
function RabbitQueueNames([string]$c) {
    return @(docker exec $c rabbitmqctl -q list_queues name --no-table-headers 2>$null | Where-Object { $_ -and ($_ -notmatch '^\s*$') } | ForEach-Object { ($_ -split "`t")[0] })
}
function RabbitQueuePolicy([string]$c, [string]$q) {
    $line = @(docker exec $c rabbitmqctl -q list_queues name policy --no-table-headers 2>$null | Where-Object { ($_ -split "`t")[0] -eq $q })
    if ($line.Count -eq 0) { return $null }
    $parts = @($line[0] -split "`t")
    if ($parts.Count -ge 2) { return $parts[1] } else { return "" }
}
function RabbitQueueMessagesReady([string]$c, [string]$q) {
    $line = docker exec $c rabbitmqctl -q list_queues name messages_ready --no-table-headers 2>$null | Where-Object { ($_ -split "`t")[0] -eq $q }
    if ($line) { return [int](($line -split "`t")[1]) } else { return -1 }
}
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
    $log = Join-Path $env:TEMP "verify-rc-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "rc-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
# Parse a CSV numeric value with the invariant culture; return $null when the
# field is not a number (for example "unavailable").
function Num([string]$s) { try { return [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null } }
# True when the ";"-joined key=value list contains exactly the given "k=v".
function HasLabel([string]$labels, [string]$kv) {
    foreach ($part in ($labels -split ';')) { if ($part -eq $kv) { return $true } }
    return $false
}
function NumericValues([object[]]$rows) {
    $vals = @()
    foreach ($r in $rows) { $n = Num ([string]$r.value); if ($null -ne $n) { $vals += $n } }
    return @($vals)
}
# Parse a CSV utc_time value (yyyy-MM-ddTHH:mm:ss.fffZ); $null on failure.
function Time([string]$s) { try { return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null } }

# ================================================================== run
try {
    # ---------------------------------------------------------- guards
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5156-5158" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-rc-definitions.json"; $conf = Join-Path $env:TEMP "verify-rc-rabbitmq.conf"
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
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`ncollect_statistics_interval = 1000`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    Start-Svc "FlashSale.OrderService" "start"
    Start-Svc "FlashSale.InventoryService" "start"
    Start-Svc "FlashSale.ProcessWorker" "start"
    $all = $allQueues + $allDlqs
    $ready = Wait-Until { @($all | Where-Object { -not (QueueExists $_) }).Count -eq 0 } 120
    Check "all three services up; every queue and DLQ declared" $ready (($all | ForEach-Object { "$_=$(QueueExists $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = $initialStock } -Force *> $null
    Check "warm-up: $p has $initialStock units" ((Stock $p) -eq "$initialStock")

    # ---------------------------------------------------------- start the collector
    Write-Output "== Start the run-time collector"
    $outDir = Join-Path $env:TEMP "verify-rc-$runId"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $collector = Join-Path $repoRoot "scripts\collect-run-metrics.ps1"
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile", "-File", $collector,
        "-RunId", $runId,
        "-OutDir", $outDir,
        "-IntervalSeconds", "$collectorInterval",
        "-DurationSeconds", "$collectorDuration",
        "-RabbitMqUrl", "http://localhost:$mgmt",
        "-RedisContainer", $redis,
        "-PostgresContainer", $Container,
        "-OrderMetricsUrl", "http://localhost:$orderPort/metrics",
        "-InventoryMetricsUrl", "http://localhost:$invPort/metrics",
        "-WorkerMetricsUrl", "http://localhost:$workerPort/metrics"
    ) -RedirectStandardOutput (Join-Path $outDir "collector.out.log") -RedirectStandardError (Join-Path $outDir "collector.err.log") -WindowStyle Hidden -PassThru
    $csvPath = Join-Path $outDir "samples.csv"
    $jsonPath = Join-Path $outDir "collector.json"
    $collectorStarted = Wait-Until { Test-Path -LiteralPath $jsonPath } 20
    Check "collector started and wrote collector.json" $collectorStarted "json=$jsonPath"
    if (-not $collectorStarted) { throw "collector did not start (see $outDir)" }

    # ---------------------------------------------------------- phase 1: orders with everything up
    Start-Sleep 4
    $placed = 0
    for ($i = 0; $i -lt 3; $i++) { $id = Post-Order $p ("rc-up-$i-" + [guid]::NewGuid()); if ($id) { $placed++ } }
    Start-Sleep 4   # let Inventory reserve (Redis calls) and the Worker complete

    # ---------------------------------------------------------- phase 2: stop Inventory, OrderPlaced backs up
    Stop-Svc "FlashSale.InventoryService"
    Start-Sleep 1
    for ($i = 0; $i -lt 3; $i++) { $id = Post-Order $p ("rc-down-$i-" + [guid]::NewGuid()); if ($id) { $placed++ } }
    Start-Sleep 12

    # ---------------------------------------------------------- phase 3: stop Redis; redis rows become unavailable
    docker stop $redis *> $null
    Start-Sleep 12

    # wait for the collector to finish on its own (-DurationSeconds 45)
    for ($i = 0; $i -lt 70; $i++) { $proc.Refresh(); if ($proc.HasExited) { break }; Start-Sleep 1 }

    # ---------------------------------------------------------- analyse samples.csv
    Write-Output "== Analyse samples.csv"
    $rows = @()
    if (Test-Path -LiteralPath $csvPath) { $rows = @(Import-Csv -LiteralPath $csvPath) }
    Check "samples.csv has rows" ($rows.Count -ge 1) "rows=$($rows.Count)"

    $srcPresent = @()
    foreach ($src in "rabbitmq", "redis", "postgres", "service", "host") {
        if (@($rows | Where-Object { $_.source -eq $src }).Count -ge 1) { $srcPresent += $src }
    }
    Check "rows from every source (rabbitmq, redis, postgres, service, host)" ($srcPresent.Count -eq 5) "present=$($srcPresent -join ',')"

    $depthRows = @($rows | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "messages_ready" -and (HasLabel $_.labels "queue=OrderPlaced") })
    $depthVals = NumericValues $depthRows
    $depthPeak = 0.0; if ($depthVals.Count -gt 0) { $depthPeak = ($depthVals | Measure-Object -Maximum).Maximum }
    Check "OrderPlaced queue depth peaked >= 1 while Inventory was stopped" ($depthPeak -ge 1) "peak=$depthPeak"

    $ageRows = @($rows | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "oldest_age_seconds" -and (HasLabel $_.labels "queue=OrderPlaced") })
    $ageVals = NumericValues $ageRows
    $ageMax = -1.0; if ($ageVals.Count -gt 0) { $ageMax = ($ageVals | Measure-Object -Maximum).Maximum }
    Check "OrderPlaced oldest message age > 0 while waiting" ($ageMax -gt 0) "max_age=$ageMax"

    $callRows = @($rows | Where-Object { $_.source -eq "redis" -and $_.name -eq "calls" })
    $callVals = NumericValues $callRows
    $callMin = 0.0; $callMax = 0.0
    if ($callVals.Count -gt 0) { $callMin = ($callVals | Measure-Object -Minimum).Minimum; $callMax = ($callVals | Measure-Object -Maximum).Maximum }
    Check "Redis calls rose during the run" ($callVals.Count -ge 2 -and $callMax -ge 1 -and $callMax -gt $callMin) "calls min=$callMin max=$callMax samples=$($callVals.Count)"

    $connOrder = NumericValues @($rows | Where-Object { $_.source -eq "postgres" -and $_.name -eq "connections" -and (HasLabel $_.labels "usename=order_service_user") })
    $connInv = NumericValues @($rows | Where-Object { $_.source -eq "postgres" -and $_.name -eq "connections" -and (HasLabel $_.labels "usename=inventory_service_user") })
    $connOrderMax = 0.0; if ($connOrder.Count -gt 0) { $connOrderMax = ($connOrder | Measure-Object -Maximum).Maximum }
    $connInvMax = 0.0; if ($connInv.Count -gt 0) { $connInvMax = ($connInv | Measure-Object -Maximum).Maximum }
    Check "connections >= 1 per service account (order_service_user, inventory_service_user)" ($connOrderMax -ge 1 -and $connInvMax -ge 1) "order=$connOrderMax inventory=$connInvMax"

    $cpuVals = NumericValues @($rows | Where-Object { $_.source -eq "host" -and $_.name -eq "cpu_percent" })
    $memUsed = NumericValues @($rows | Where-Object { $_.source -eq "host" -and $_.name -eq "memory_used_bytes" })
    $memTotal = NumericValues @($rows | Where-Object { $_.source -eq "host" -and $_.name -eq "memory_total_bytes" })
    $memTotalMax = 0.0; if ($memTotal.Count -gt 0) { $memTotalMax = ($memTotal | Measure-Object -Maximum).Maximum }
    $memUsedMax = 0.0; if ($memUsed.Count -gt 0) { $memUsedMax = ($memUsed | Measure-Object -Maximum).Maximum }
    Check "host CPU and memory present" ($cpuVals.Count -ge 1 -and $memTotalMax -gt 0 -and $memUsedMax -ge 0 -and $memUsedMax -le $memTotalMax) "cpu_samples=$($cpuVals.Count) mem_used=$memUsedMax mem_total=$memTotalMax"

    $accRows = @($rows | Where-Object { $_.source -eq "service" -and $_.name -eq "flashsale_orders_accepted_total" -and (HasLabel $_.labels "service=order-service") })
    $accVals = NumericValues $accRows
    $accMax = 0.0; if ($accVals.Count -gt 0) { $accMax = ($accVals | Measure-Object -Maximum).Maximum }
    Check "accepted counter rose by the number of orders placed" ($accMax -ge $placed) "accepted_max=$accMax placed=$placed"

    # cadence: one collector/sample_duration_ms row per sample; the mean gap
    # between consecutive sample timestamps must be at most interval + 1 s.
    $sampleTimes = @($rows | Where-Object { $_.source -eq "collector" -and $_.name -eq "sample_duration_ms" } | ForEach-Object { Time ([string]$_.utc_time) } | Where-Object { $null -ne $_ } | Sort-Object)
    $gaps = @()
    for ($i = 1; $i -lt $sampleTimes.Count; $i++) { $gaps += ($sampleTimes[$i] - $sampleTimes[$i - 1]).TotalSeconds }
    $meanGap = 0.0; if ($gaps.Count -gt 0) { $meanGap = ($gaps | Measure-Object -Average).Average }
    $durations = NumericValues @($rows | Where-Object { $_.source -eq "collector" -and $_.name -eq "sample_duration_ms" })
    $meanDuration = 0.0; if ($durations.Count -gt 0) { $meanDuration = ($durations | Measure-Object -Average).Average }
    Check "sampling cadence: mean gap <= interval + 1 s" ($gaps.Count -ge 1 -and $meanGap -le ($collectorInterval + 1)) "mean_gap=$meanGap gaps=$($gaps.Count) mean_sample_ms=$meanDuration"

    $missingQueueRows = @($allQueues | Where-Object {
        $q = $_
        @($rows | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "messages_ready" -and (HasLabel $_.labels "queue=$q") }).Count -lt 1
    })
    Check "every main queue has messages_ready rows" ($missingQueueRows.Count -eq 0) "missing=$($missingQueueRows -join ',')"

    $unavail = @($rows | Where-Object { $_.source -eq "redis" -and $_.value -eq "unavailable" })
    $unavailTimes = @($unavail | Sort-Object utc_time | ForEach-Object { $_.utc_time })
    $firstUnavail = $null; if ($unavailTimes.Count -ge 1) { $firstUnavail = $unavailTimes[0] }
    $keptGoing = $true
    if ($null -ne $firstUnavail) {
        foreach ($src in "rabbitmq", "service", "host") {
            if (@($rows | Where-Object { $_.source -eq $src -and ($_.utc_time -ge $firstUnavail) }).Count -lt 1) { $keptGoing = $false }
        }
    } else { $keptGoing = $false }
    Check "Redis rows became unavailable (not 0) while Redis was stopped, and the other sources kept sampling" (($unavail.Count -ge 1) -and $keptGoing) "unavailable_rows=$($unavail.Count) first=$firstUnavail"

    $jsonOk = $false
    if (Test-Path -LiteralPath $jsonPath) {
        try {
            $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
            $wantCommit = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
            $jsonOk = ($j.run_id -eq $runId) -and ($j.interval_seconds -eq $collectorInterval) -and ($j.git_commit -eq $wantCommit)
            $jsonDetail = "run_id=$($j.run_id) interval=$($j.interval_seconds) (want $collectorInterval) commit=$($j.git_commit) (want $wantCommit)"
        } catch { $jsonOk = $false; $jsonDetail = "unreadable: $($_.Exception.Message)" }
    } else { $jsonDetail = "missing: $jsonPath" }
    Check "collector.json records run id, interval and git commit" $jsonOk $jsonDetail

    # ---------------------------------------------------------- container-mode broker (no 15672)
    Write-Output "== Container-mode collector + set-queue-bounds (no published management port)"
    docker rm -f $mq2 *> $null
    $defs2 = Join-Path $env:TEMP "verify-rc-definitions2.json"; $conf2 = Join-Path $env:TEMP "verify-rc-rabbitmq2.conf"
    # Loading definitions at boot skips the default user, so the same account
    # as the main broker is defined (the in-container publish below uses it).
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        queues = @(
            @{ name = "OrderPlaced"; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} }
            @{ name = "OrderPlaced.dlq"; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content $defs2 -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf2 -Encoding ASCII
    # no 15672 mapping: only the amqp port is published (the EC2 shape)
    docker run -d --name $mq2 -v "${defs2}:/etc/rabbitmq/definitions.json:ro" -v "${conf2}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp2}:5672" rabbitmq:3-management | Out-Null
    # No rabbitmqctl before the broker has booted: a `docker exec` (root) call
    # that early creates /var/lib/rabbitmq/.erlang.cookie owned by root, and the
    # broker (user rabbitmq) then crashes with "eacces" reading it.
    Wait-Until { @(docker logs $mq2 2>&1 | Select-String -SimpleMatch "Server startup complete").Count -gt 0 } 90 | Out-Null
    $mq2Ready = Wait-Until { $n = RabbitQueueNames $mq2; ($n -contains "OrderPlaced") -and ($n -contains "OrderPlaced.dlq") } 90
    Check "container-mode broker up: OrderPlaced and OrderPlaced.dlq declared (no 15672 published)" $mq2Ready "queues=$(RabbitQueueNames $mq2 -join ',')"
    if (-not $mq2Ready) { throw "container-mode broker did not come up" }

    # Publish one message into OrderPlaced via the management API INSIDE the
    # container (bash /dev/tcp; no published port, no curl/rabbitmqadmin).
    $publishScript = @'
set -e
body='{"properties":{},"routing_key":"OrderPlaced","payload":"hello","payload_encoding":"string"}'
len=${#body}
exec 3<>/dev/tcp/127.0.0.1/15672
printf 'POST /api/exchanges/%%2F/amq.default/publish HTTP/1.1\r\nHost: 127.0.0.1:15672\r\nAuthorization: Basic Zmxhc2hzYWxlOmZsYXNoc2FsZV9kZXY=\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$len" "$body" >&3
cat <&3
'@
    $pubOk = $false
    for ($i = 0; $i -lt 8; $i++) {
        # Base64 in the command, not stdin: PowerShell 5.1 adds a BOM and CRLF to piped text.
        $pub64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($publishScript -replace "`r", "")))
        docker exec $mq2 bash -c "echo $pub64 | base64 -d | bash" *> $null
        Start-Sleep 1
        if ((RabbitQueueMessagesReady $mq2 "OrderPlaced") -ge 1) { $pubOk = $true; break }
    }
    Check "container-mode publish: OrderPlaced holds at least one message" $pubOk "messages_ready=$(RabbitQueueMessagesReady $mq2 'OrderPlaced')"

    # Run the collector in container mode with a random RABBITMQ_PASSWORD so the
    # password and flashsale_dev must not appear anywhere in its output.
    $randomPw = "rc-secret-" + [guid]::NewGuid().ToString("N")
    $oldPw = $env:RABBITMQ_PASSWORD
    $env:RABBITMQ_PASSWORD = $randomPw
    $outDir2 = Join-Path $env:TEMP "verify-rc2-$runId"
    New-Item -ItemType Directory -Force -Path $outDir2 | Out-Null
    $proc2 = Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile", "-File", $collector,
        "-RunId", ($runId + "-c"),
        "-OutDir", $outDir2,
        "-IntervalSeconds", "5",
        "-DurationSeconds", "8",
        "-RabbitMqContainer", $mq2,
        "-RedisContainer", $redis,
        "-PostgresContainer", $Container
    ) -RedirectStandardOutput (Join-Path $outDir2 "collector.out.log") -RedirectStandardError (Join-Path $outDir2 "collector.err.log") -WindowStyle Hidden -PassThru
    $env:RABBITMQ_PASSWORD = $oldPw
    $csv2 = Join-Path $outDir2 "samples.csv"
    $json2 = Join-Path $outDir2 "collector.json"
    $collector2Started = Wait-Until { Test-Path -LiteralPath $json2 } 20
    Check "container-mode collector started and wrote collector.json" $collector2Started "json=$json2"
    if ($collector2Started) { for ($i = 0; $i -lt 30; $i++) { $proc2.Refresh(); if ($proc2.HasExited) { break }; Start-Sleep 1 } }
    $rows2 = @()
    if (Test-Path -LiteralPath $csv2) { $rows2 = @(Import-Csv -LiteralPath $csv2) }

    $depthRows2 = @($rows2 | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "messages_ready" -and (HasLabel $_.labels "queue=OrderPlaced") })
    $depthVals2 = NumericValues $depthRows2
    $depthPeak2 = 0.0; if ($depthVals2.Count -gt 0) { $depthPeak2 = ($depthVals2 | Measure-Object -Maximum).Maximum }
    Check "container-mode: OrderPlaced messages_ready rows exist and peak >= 1" ($depthRows2.Count -ge 1 -and $depthPeak2 -ge 1) "rows=$($depthRows2.Count) peak=$depthPeak2"

    $rateOk = $true; $rateDetail = ""
    foreach ($rn in "publish_rate", "deliver_get_rate", "ack_rate") {
        $rr = @($rows2 | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq $rn -and $_.value -eq "unavailable" -and (HasLabel $_.labels "reason=no management API in container mode") })
        if ($rr.Count -lt 1) { $rateOk = $false; $rateDetail += "$rn:missing; " }
    }
    Check "container-mode: publish/deliver/ack rate rows are unavailable with the reason" $rateOk $rateDetail

    $mode2 = ""
    if (Test-Path -LiteralPath $json2) {
        try { $j2 = Get-Content -LiteralPath $json2 -Raw | ConvertFrom-Json; $mode2 = [string]$j2.endpoints.rabbitmq.mode } catch { $mode2 = "" }
    }
    Check "container-mode: collector.json rabbitmq mode = container" ($mode2 -eq "container") "mode=$mode2"

    $json2Raw = if (Test-Path -LiteralPath $json2) { Get-Content -LiteralPath $json2 -Raw } else { "" }
    $csv2Raw = if (Test-Path -LiteralPath $csv2) { Get-Content -LiteralPath $csv2 -Raw } else { "" }
    $leakDefault = (($json2Raw -like "*flashsale_dev*") -or ($csv2Raw -like "*flashsale_dev*"))
    $leakRandom = (($json2Raw -like "*$randomPw*") -or ($csv2Raw -like "*$randomPw*"))
    Check "container-mode: flashsale_dev and the RABBITMQ_PASSWORD value appear nowhere" ((-not $leakDefault) -and (-not $leakRandom)) "flashsale_dev=$leakDefault randomPw=$leakRandom"

    # set-queue-bounds on the unpublished-port broker (rabbitmqctl path)
    & (Join-Path $repoRoot "scripts\set-queue-bounds.ps1") -Container $mq2 -MaxLength 3 *> $null
    $polMain = RabbitQueuePolicy $mq2 "OrderPlaced"
    $polDlq = RabbitQueuePolicy $mq2 "OrderPlaced.dlq"
    Check "set-queue-bounds (rabbitmqctl): policy on OrderPlaced, not on OrderPlaced.dlq" (($polMain -eq "flashsale-c3-bounds") -and ($polDlq -ne "flashsale-c3-bounds")) "main=$polMain dlq=$polDlq"
    & (Join-Path $repoRoot "scripts\set-queue-bounds.ps1") -Container $mq2 -Remove *> $null
    Check "set-queue-bounds -Remove (rabbitmqctl): policy gone from OrderPlaced" ((RabbitQueuePolicy $mq2 "OrderPlaced") -ne "flashsale-c3-bounds") "policy=$(RabbitQueuePolicy $mq2 'OrderPlaced')"

    # the management-API path must still work on a broker that DOES publish 15672
    & (Join-Path $repoRoot "scripts\set-queue-bounds.ps1") -Container $mq -MaxLength 3 *> $null
    $polMqMain = RabbitQueuePolicy $mq "OrderPlaced"
    $polMqDlq = RabbitQueuePolicy $mq "OrderPlaced.dlq"
    Check "set-queue-bounds management-API path still applies (published 15672)" (($polMqMain -eq "flashsale-c3-bounds") -and ($polMqDlq -ne "flashsale-c3-bounds")) "main=$polMqMain dlq=$polMqDlq"
    & (Join-Path $repoRoot "scripts\set-queue-bounds.ps1") -Container $mq -Remove *> $null
    Check "set-queue-bounds management-API path -Remove" ((RabbitQueuePolicy $mq "OrderPlaced") -ne "flashsale-c3-bounds") "policy=$(RabbitQueuePolicy $mq 'OrderPlaced')"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if ($proc2 -and -not $proc2.HasExited) { Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue }
    foreach ($project in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $project }
    foreach ($c in $mq, $redis, $mq2) { docker rm -f $c *> $null }
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: the run-time collector sampled every source and recorded a failing source as unavailable, never 0."
exit 0
