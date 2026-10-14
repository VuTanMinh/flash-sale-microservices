# ============================================================
# Week 11 milestone, Task A (TP-P06): every published message carries the AMQP
# timestamp property, so the broker's head_message_timestamp can report the
# oldest-message age. This verifier proves it for each of the six publish sites:
#
#   powershell -File .\scripts\verify-message-timestamps.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5692/15692) and Redis (6392) against the given PostgreSQL container.
# Services run on ports 5150 (Order), 5151 (Inventory) and 5152 (Worker).
#
# For each of the six paths it makes a message sit in a queue (by not starting
# that queue's consumer), reads the head message with
#   POST /api/queues/%2F/<q>/get  { count=1, ackmode="reject_requeue_true" }
# and checks properties.timestamp is present, positive and the publish moment,
# and that the queue's head_message_timestamp (GET /api/queues/%2F/<q>) gives
# an age that grows while the message waits.
#
# Paths:
#   P1  OrderPlaced            (Order Service Outbox)        -> OrderPlaced
#   P2  StockReserved          (Inventory Service Outbox)    -> StockReserved
#   P3  OrderProcessed         (Process Worker)              -> OrderProcessed
#   P4  OrderProcessingStarted (Process Worker)              -> OrderProcessingStarted
#   P5  OrderProcessed delayed requeue (Order Service)       -> OrderProcessed.retry.3
#   P6  OrderProcessingStarted delayed requeue (Order Service) -> OrderProcessingStarted.retry.3
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 40     # 2 setup + 6 paths x 6 Check calls + 2 order-created checks (a truncated run must fail)
$mq = "verify-ts-mq"; $amqp = 5692; $mgmt = 15692; $redis = "verify-ts-redis"; $redisPort = 6392
$orderPort = 5150; $invPort = 5151; $workerPort = 5152
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}   # project -> current log file
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "ts-$runId"                     # warmed product, used by every real reservation
$initialStock = 20
$mainQueues = "OrderPlaced", "StockReserved", "StockRejected", "ProcessWorker.StockReserved", "OrderProcessingStarted", "OrderProcessed"
$retryQueues = "OrderProcessed.retry.1", "OrderProcessed.retry.2", "OrderProcessed.retry.3", "OrderProcessingStarted.retry.1", "OrderProcessingStarted.retry.2", "OrderProcessingStarted.retry.3"

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
# Queue counts come from rabbitmqctl in the broker, not the management API
# statistics, which lag.
function QueueDepth([string]$q) {
    $line = docker exec $mq rabbitmqctl -q list_queues name messages --no-table-headers 2>$null | Where-Object { ($_ -split "`t")[0] -eq $q }
    if ($line) { return [int](($line -split "`t")[1]) } else { return -1 }
}
function QueueExists([string]$q) { return ($null -ne (Mq Get "/queues/%2F/$q")) }
function Purge([string]$q) { docker exec $mq rabbitmqctl purge_queue $q *> $null }
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
    $log = Join-Path $env:TEMP "verify-ts-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "ts-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function Publish([string]$eventType, [string]$payload) {
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $eventType; content_type = "application/json" }; routing_key = $eventType; payload = $payload; payload_encoding = "string" } | Out-Null
}
function OrderPlacedPayload([string]$productId) {
    return "{`"OrderId`":`"$([guid]::NewGuid())`",`"ProductId`":`"$productId`",`"Quantity`":1,`"MessageId`":`"$([guid]::NewGuid())`",`"CorrelationId`":`"verify-message-timestamps`"}"
}
function OrderProcessedPayload([string]$orderId) {
    $startedAt = (Get-Date).ToUniversalTime().ToString("o")
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$orderId`",`"CorrelationId`":`"verify-message-timestamps`",`"ProcessingStartedAt`":`"$startedAt`"}"
}
function OrderProcessingStartedPayload([string]$orderId) {
    $startedAt = (Get-Date).ToUniversalTime().ToString("o")
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$([guid]::NewGuid())`",`"CorrelationId`":`"verify-message-timestamps`",`"StartedAt`":`"$startedAt`"}"
}
function HeadTimestamp([string]$q) {
    $info = Mq Get "/queues/%2F/$q"
    if ($info -and $info.head_message_timestamp) { return [long]$info.head_message_timestamp } else { return -1 }
}
function GetHead([string]$q) {
    $resp = Mq Post "/queues/%2F/$q/get" @{ count = 1; ackmode = "reject_requeue_true"; encoding = "auto" }
    if ($null -eq $resp) { return $null }
    $arr = @($resp)
    if ($arr.Count -ge 1 -and $null -ne $arr[0]) { return $arr[0] } else { return $null }
}
# The one workhorse: wait for a message to sit in $queue, then prove it carries a
# fresh publish timestamp and that its head_message_timestamp age grows. Always
# emits exactly six Check lines (pass or fail), so a truncated run is caught.
function Check-TimestampedMessage([string]$queue, [string]$label, [long]$tBefore) {
    $seen = Wait-Until { (QueueDepth $queue) -ge 1 } 60
    $depth = QueueDepth $queue
    Check "${label}: message sits in $queue" $seen "depth=$depth"
    if ($seen) {
        # head_message_timestamp is a management statistic refreshed every
        # collect_statistics_interval (1 s on the throwaway broker), so it lags
        # the message's arrival; poll until the broker reports it.
        $headReady = Wait-Until { (HeadTimestamp $queue) -gt 0 } 10
        $tAfter = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $h1 = HeadTimestamp $queue
        $msg = GetHead $queue
        $pTs = 0; if ($null -ne $msg) { $pTs = [long]$msg.properties.timestamp }
        Check "${label}: head_message_timestamp present" ($headReady -and $h1 -gt 0) "head=$h1"
        Check "${label}: properties.timestamp present and positive" ($pTs -gt 0) "timestamp=$pTs"
        Check "${label}: timestamp is the publish moment (not stale, not future)" ($pTs -ge ($tBefore - 5) -and $pTs -le $tAfter) "ts=$pTs window=$($tBefore - 5)..$tAfter"
        Check "${label}: head_message_timestamp matches the message timestamp" ($h1 -gt 0 -and $pTs -gt 0 -and [math]::Abs($h1 - $pTs) -le 1) "head=$h1 ts=$pTs"
        Start-Sleep 3
        $h2 = HeadTimestamp $queue
        $now2 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $age1 = $tAfter - $h1
        $age2 = $now2 - $h2
        Check "${label}: head_message_timestamp age grows while the message waits" (($h1 -gt 0) -and ($h2 -eq $h1) -and (($age2 - $age1) -ge 2)) "head $h1 -> $h2, age ${age1}s -> ${age2}s"
    } else {
        Check "${label}: head_message_timestamp present" $false "no message"
        Check "${label}: properties.timestamp present and positive" $false "no message"
        Check "${label}: timestamp is the publish moment (not stale, not future)" $false "no message"
        Check "${label}: head_message_timestamp matches the message timestamp" $false "no message"
        Check "${label}: head_message_timestamp age grows while the message waits" $false "no message"
    }
}

# ================================================================== run
try {
    # ---------------------------------------------------------- guards
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5150-5152" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-ts-definitions.json"; $conf = Join-Path $env:TEMP "verify-ts-rabbitmq.conf"
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
    $all = $mainQueues + $retryQueues
    $ready = Wait-Until { @($all | Where-Object { -not (QueueExists $_) }).Count -eq 0 } 120
    Check "all three services up; every main and retry queue declared" $ready (($all | ForEach-Object { "$_=$(QueueExists $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = $initialStock } -Force *> $null
    Check "warm-up: $p has $initialStock units" ((Stock $p) -eq "$initialStock")

    # ---------------------------------------------------------- P1. OrderPlaced (Order outbox)
    Write-Output "== P1. OrderPlaced (Order Service outbox)"
    Stop-Svc "FlashSale.InventoryService"
    Purge "OrderPlaced"
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Post-Order $p ("ts-p1-" + [guid]::NewGuid()) | Out-Null
    Check-TimestampedMessage "OrderPlaced" "P1 OrderPlaced" $t
    Purge "OrderPlaced"

    # ---------------------------------------------------------- P2. StockReserved (Inventory outbox)
    Write-Output "== P2. StockReserved (Inventory Service outbox)"
    Start-Svc "FlashSale.InventoryService" "p2"
    Stop-Svc "FlashSale.OrderService"
    Stop-Svc "FlashSale.ProcessWorker"
    Purge "StockReserved"; Purge "ProcessWorker.StockReserved"; Purge "OrderPlaced"
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Publish "OrderPlaced" (OrderPlacedPayload $p)
    Check-TimestampedMessage "StockReserved" "P2 StockReserved" $t
    Purge "StockReserved"; Purge "ProcessWorker.StockReserved"; Purge "OrderPlaced"

    # ---------------------------------------------------------- P3/P4. Worker events
    Write-Output "== P3/P4. OrderProcessed and OrderProcessingStarted (Process Worker)"
    Start-Svc "FlashSale.ProcessWorker" "p3"
    Purge "OrderProcessingStarted"; Purge "OrderProcessed"; Purge "StockReserved"; Purge "ProcessWorker.StockReserved"; Purge "OrderPlaced"
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Publish "OrderPlaced" (OrderPlacedPayload $p)
    Check-TimestampedMessage "OrderProcessingStarted" "P4 OrderProcessingStarted" $t
    Check-TimestampedMessage "OrderProcessed" "P3 OrderProcessed" $t
    Purge "OrderProcessingStarted"; Purge "OrderProcessed"; Purge "StockReserved"; Purge "ProcessWorker.StockReserved"; Purge "OrderPlaced"

    # ---------------------------------------------------------- P5. OrderProcessed delayed requeue
    Write-Output "== P5. OrderProcessed delayed requeue (Order Service)"
    Stop-Svc "FlashSale.ProcessWorker"
    Stop-Svc "FlashSale.InventoryService"
    Start-Svc "FlashSale.OrderService" "p5"
    Purge "OrderProcessed"; Purge "OrderProcessed.retry.1"; Purge "OrderProcessed.retry.2"; Purge "OrderProcessed.retry.3"
    $id5 = Post-Order $p ("ts-p5-" + [guid]::NewGuid())
    Check "P5: order $id5 created and still PendingStock" ($id5 -ne "" -and (State $id5) -eq "PendingStock") "state=$(State $id5)"
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Publish "OrderProcessed" (OrderProcessedPayload $id5)
    Check-TimestampedMessage "OrderProcessed.retry.3" "P5 OrderProcessed requeue" $t
    Purge "OrderProcessed"; Purge "OrderProcessed.retry.1"; Purge "OrderProcessed.retry.2"; Purge "OrderProcessed.retry.3"

    # ---------------------------------------------------------- P6. OrderProcessingStarted delayed requeue
    Write-Output "== P6. OrderProcessingStarted delayed requeue (Order Service)"
    Purge "OrderProcessingStarted"; Purge "OrderProcessingStarted.retry.1"; Purge "OrderProcessingStarted.retry.2"; Purge "OrderProcessingStarted.retry.3"
    $id6 = Post-Order $p ("ts-p6-" + [guid]::NewGuid())
    Check "P6: order $id6 created and still PendingStock" ($id6 -ne "" -and (State $id6) -eq "PendingStock") "state=$(State $id6)"
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Publish "OrderProcessingStarted" (OrderProcessingStartedPayload $id6)
    Check-TimestampedMessage "OrderProcessingStarted.retry.3" "P6 OrderProcessingStarted requeue" $t
    Purge "OrderProcessingStarted"; Purge "OrderProcessingStarted.retry.1"; Purge "OrderProcessingStarted.retry.2"; Purge "OrderProcessingStarted.retry.3"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    docker unpause $mq *> $null
    foreach ($project in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $project }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: every publish site stamps a fresh timestamp and the oldest-message age grows while a message waits."
exit 0
