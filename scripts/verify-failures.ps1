# ============================================================
# Week 10 TP-F01 (docs/failure-handling.md): each consumer's retry is bounded,
# a message that fails for good lands in the CORRECT service's DLQ, a poison
# (malformed or empty-identity) message is dead-lettered after one attempt, and
# an exhausted message can be replayed after the fix.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-failures.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5690/15690) and Redis (6399) against the given PostgreSQL container.
# For each of the four consumers it shows:
#   Transient: a fault fixed inside the retry window (a revoked Inbox INSERT
#              restored after ~2 s; for the Worker, a missing required
#              OrderProcessed queue that is recreated) -> applied once, nothing
#              dead-lettered, the log shows retries.
#   Exhausted: the fault outlasts the ladder -> exactly 4 attempts logged with
#              ~1 s / 2 s / 4 s gaps (timestamps), the message in THAT service's
#              DLQ with x-death naming the source queue and reason "rejected",
#              the main queue empty (no loop), every other DLQ unchanged.
#   Poison:    malformed JSON, and a well-formed message with an empty
#              MessageId -> that service's DLQ after one attempt (no retry log
#              lines), no Inbox row, no Redis or state change; two different
#              empty-MessageId messages BOTH reach the DLQ.
#   Replay:    the exhausted message republished unchanged -> applied once.
#   Quantity:  an OrderPlaced with Quantity != 1 is permanent (03 P1) -> its
#              DLQ after one attempt, no Lua call, no Redis change, no rows.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-fl-mq"; $amqp = 5690; $mgmt = 15690; $redis = "verify-fl-redis"; $redisPort = 6399
$orderPort = 5132; $invPort = 5133; $workerPort = 5134
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "fl-$runId"
$empty = "00000000-0000-0000-0000-000000000000"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed", "ProcessWorker.StockReserved"

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
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
function QueueCount([string]$q) { $r = Mq Get "/queues/%2F/$q"; if ($r) { return [int]$r.messages } else { return -1 } }
function QueueExists([string]$q) { return ($null -ne (Mq Get "/queues/%2F/$q")) }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis([string[]]$cmd) { return (docker exec $redis redis-cli @cmd | Out-String).Trim() }
function Log([string]$project) {
    if (-not $logs[$project]) { return "" }
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
    $log = Join-Path $env:TEMP "verify-fl-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "fl-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function OrdInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvOutbox([string]$id) { return (Int1 "SELECT count(*) FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id';") }
function Stock([string]$product) { return (Redis "GET", "inventory:$product") }
function Publish([string]$eventType, [string]$payload) {
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $eventType; content_type = "application/json" }; routing_key = $eventType; payload = $payload; payload_encoding = "string" } | Out-Null
}
function OrderPlacedPayload([string]$orderId, [string]$messageId, [string]$productId, [int]$quantity = 1) {
    return "{`"OrderId`":`"$orderId`",`"ProductId`":`"$productId`",`"Quantity`":$quantity,`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-failures`"}"
}
function StockReservedPayload([string]$orderId, [string]$messageId, [string]$productId) {
    return "{`"OrderId`":`"$orderId`",`"ProductId`":`"$productId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-failures`"}"
}
function OrderProcessedPayload([string]$orderId, [string]$messageId) {
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-failures`"}"
}
function Purge([string]$q) { Mq Delete "/queues/%2F/$q/contents" | Out-Null }
function DeleteQueue([string]$q) { Mq Delete "/queues/%2F/$q" | Out-Null }
function DeclareQueue([string]$q) { Mq Put "/queues/%2F/$q" @{ durable = $true; auto_delete = $false; arguments = @{} } | Out-Null }
function Drain([string]$q) { Mq Post "/queues/%2F/$q/get" @{ count = 100; ackmode = "ack_requeue_false"; encoding = "auto" } | Out-Null }
function DlqGet([string]$q, [int]$count = 1) { return @(Mq Post "/queues/%2F/$q/get" @{ count = $count; ackmode = "ack_requeue_false"; encoding = "auto" } | ForEach-Object { $_ }) }
function DlqSnapshot { $h = @{}; foreach ($q in $allDlqs) { $h[$q] = QueueCount $q }; return $h }
function IsolationDrift([hashtable]$before, [string]$target) {
    $drift = @()
    foreach ($q in $allDlqs) {
        if ($q -eq $target) { continue }
        $now = QueueCount $q
        if ($now -ne $before[$q]) { $drift += "$q=$($before[$q])->$now" }
    }
    return ($drift -join ", ")
}
function DlqDeath([object]$m) {
    $hdrs = $null
    if ($m.properties -and $m.properties.headers) { $hdrs = $m.properties.headers }
    elseif ($m.headers) { $hdrs = $m.headers }
    if (-not $hdrs) { return @() }
    return @($hdrs.'x-death' | ForEach-Object { $_ })
}
function DeathHas([object]$m, [string]$queue, [string]$reason) {
    return (@(DlqDeath $m | Where-Object { $_.queue -eq $queue -and $_.reason -eq $reason }).Count -ge 1)
}
function LogSeconds([string]$ts) {
    if ($ts -notmatch '^(\d{2}):(\d{2}):(\d{2})$') { return -1 }
    return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
}
function RetryTimestamps([string]$project, [string]$needle) {
    $text = Log $project
    if (-not $text) { return @() }
    $ts = @()
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^\[(\d{2}:\d{2}:\d{2}) ' -and $l.Contains($needle) -and ($l.Contains("retrying in") -or $l.Contains("after 4 attempts"))) {
            $ts += (LogSeconds $Matches[1])
        }
    }
    return @($ts)
}
function Gaps([int[]]$ts) {
    $g = @()
    for ($i = 1; $i -lt $ts.Count; $i++) { $g += ((($ts[$i] - $ts[$i - 1]) + 86400) % 86400) }
    return @($g)
}
function TotalRetryWarnings([string]$project) {
    $text = Log $project
    if (-not $text) { return 0 }
    return @([regex]::Matches($text, "retrying in")).Count
}
function LogLineCount([string]$project, [string]$needle) {
    $text = Log $project
    if (-not $text) { return 0 }
    return @($text -split "`r?`n" | Where-Object { $_.Contains($needle) }).Count
}
# Asserts the 1 s / 2 s / 4 s ladder: exactly 4 attempt lines, gaps within
# tolerant bounds (HH:mm:ss log timestamps truncate, and each attempt has a
# little processing overhead, so 1/2/4 may read 1-3 / 2-4 / 4-7).
function CheckRetryLadder([string]$project, [string]$needle, [string]$label) {
    $ts = RetryTimestamps $project $needle
    $gaps = Gaps $ts
    Check "${label}: exactly 4 attempts logged" ($ts.Count -eq 4) "attempt lines=$($ts.Count)"
    Check "${label}: retry gaps are ~1 s / 2 s / 4 s" ($gaps.Count -eq 3 -and $gaps[0] -ge 1 -and $gaps[0] -le 3 -and $gaps[1] -ge 2 -and $gaps[1] -le 4 -and $gaps[2] -ge 4 -and $gaps[2] -le 7) "gaps=$($gaps -join ',')"
}

try {
    # ---------------------------------------------------------- guards
    Write-Host "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5132-5134" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-fl-definitions.json"; $conf = Join-Path $env:TEMP "verify-fl-rabbitmq.conf"
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
    Check "all three services up; every queue and DLQ declared" $ready (($all | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 20 } -Force *> $null
    Check "warm-up: $p has 20 units" ((Stock $p) -eq "20")

    # ======================================================== A. Inventory OrderPlacedConsumer
    Write-Host "== A. Inventory OrderPlacedConsumer (OrderPlaced -> OrderPlaced.dlq)"

    # A.1 transient: Inbox INSERT revoked, restored after ~2 s
    $stockBefore = [int](Stock $p)
    $a1 = [guid]::NewGuid().ToString(); $ma1 = [guid]::NewGuid().ToString()
    Sql "REVOKE INSERT ON inventory_service.processed_messages FROM inventory_service_user;" | Out-Null
    Publish "OrderPlaced" (OrderPlacedPayload $a1 $ma1 $p)
    Start-Sleep 2
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user;" | Out-Null
    $applied = Wait-Until { (InvInbox $ma1) -eq 1 } 30
    Check "A.1 Inventory transient: applied once (1 Inbox row, 1 Outbox row, 1 unit taken)" ($applied -and (InvOutbox $a1) -eq 1 -and [int](Stock $p) -eq ($stockBefore - 1)) "stock=$($stockBefore)->$(Stock $p)"
    Check "A.1 Inventory transient: nothing dead-lettered" ((QueueCount "OrderPlaced.dlq") -eq 0) "dlq=$(QueueCount 'OrderPlaced.dlq')"
    Check "A.1 Inventory transient: the log shows a retry" (@($(Log "FlashSale.InventoryService") -split "`r?`n" | Where-Object { $_.Contains($ma1) -and $_.Contains("retrying in") }).Count -ge 1)

    # A.2 exhausted: Inbox INSERT stays revoked -> dead-lettered
    Drain "OrderPlaced.dlq"
    Wait-Until { (QueueCount "OrderPlaced") -eq 0 } 20 | Out-Null
    $dlqSnap = DlqSnapshot
    $stockBefore = [int](Stock $p)
    $a2 = [guid]::NewGuid().ToString(); $ma2 = [guid]::NewGuid().ToString()
    Sql "REVOKE INSERT ON inventory_service.processed_messages FROM inventory_service_user;" | Out-Null
    Publish "OrderPlaced" (OrderPlacedPayload $a2 $ma2 $p)
    $dead = Wait-Until { (QueueCount "OrderPlaced.dlq") -eq ($dlqSnap["OrderPlaced.dlq"] + 1) } 60
    $msg = @(DlqGet "OrderPlaced.dlq" 1)[0]
    Check "A.2 Inventory exhausted: retried then dead-lettered to OrderPlaced.dlq" $dead "dlq=$(QueueCount 'OrderPlaced.dlq')"
    CheckRetryLadder "FlashSale.InventoryService" $ma2 "A.2 Inventory"
    Check "A.2 Inventory exhausted: x-death names source OrderPlaced and reason rejected" (DeathHas $msg "OrderPlaced" "rejected")
    $drained = Wait-Until { (QueueCount "OrderPlaced") -eq 0 } 15
    Check "A.2 Inventory exhausted: main queue empty (no loop)" $drained "OrderPlaced=$(QueueCount 'OrderPlaced')"
    Check "A.2 Inventory exhausted: no Inbox row, no Outbox row, stock reserved exactly once on attempt 1" ((InvInbox $ma2) -eq 0 -and (InvOutbox $a2) -eq 0 -and [int](Stock $p) -eq ($stockBefore - 1)) "stock=$($stockBefore)->$(Stock $p)"
    Check "A.2 Inventory exhausted: every other DLQ unchanged (isolation)" ((IsolationDrift $dlqSnap "OrderPlaced.dlq") -eq "") (IsolationDrift $dlqSnap "OrderPlaced.dlq")

    # A.2 replay: republish the dead letter unchanged -> applied once (DUPLICATE)
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user;" | Out-Null
    Publish "OrderPlaced" $msg.payload
    $done = Wait-Until { (InvInbox $ma2) -eq 1 } 30
    Check "A.2 Inventory replay: applied once (1 Inbox row, 1 Outbox row, still exactly 1 unit taken)" ($done -and (InvOutbox $a2) -eq 1 -and [int](Stock $p) -eq ($stockBefore - 1)) "stock=$(Stock $p)"

    # A.3 poison: malformed JSON and empty MessageId
    Drain "OrderPlaced.dlq"
    $warnBefore = TotalRetryWarnings "FlashSale.InventoryService"
    Publish "OrderPlaced" "{this is not valid json"
    $dead = Wait-Until { (QueueCount "OrderPlaced.dlq") -eq 1 } 30
    Start-Sleep 2
    Check "A.3 Inventory poison: malformed JSON dead-lettered after one attempt" $dead "dlq=$(QueueCount 'OrderPlaced.dlq')"
    Check "A.3 Inventory poison: malformed JSON produced no retry lines" ((TotalRetryWarnings "FlashSale.InventoryService") -eq $warnBefore)
    $stockBefore = [int](Stock $p)
    Publish "OrderPlaced" (OrderPlacedPayload ([guid]::NewGuid()) $empty $p)
    $dead = Wait-Until { (QueueCount "OrderPlaced.dlq") -eq 2 } 30
    Check "A.3 Inventory poison: empty-MessageId message dead-lettered after one attempt" $dead "dlq=$(QueueCount 'OrderPlaced.dlq')"
    Check "A.3 Inventory poison: empty-MessageId logged the validation error" ((Log "FlashSale.InventoryService") -match "Invalid OrderPlaced message: MessageId is empty")
    Check "A.3 Inventory poison: no Inbox row and no Redis effect" ((InvInbox $empty) -eq 0 -and [int](Stock $p) -eq $stockBefore) "stock=$(Stock $p)"
    Publish "OrderPlaced" (OrderPlacedPayload ([guid]::NewGuid()) $empty $p)
    $dead = Wait-Until { (QueueCount "OrderPlaced.dlq") -eq 3 } 30
    Check "A.3 Inventory poison: a SECOND empty-MessageId message also reaches the DLQ (no duplicate-identity skip)" $dead "dlq=$(QueueCount 'OrderPlaced.dlq')"

    # A.4 quantity: Quantity != 1 is permanent (03 P1) -- no Lua, no Redis, no rows
    $a4 = [guid]::NewGuid().ToString(); $ma4 = [guid]::NewGuid().ToString()
    $stockBefore = [int](Stock $p)
    $warnBefore = TotalRetryWarnings "FlashSale.InventoryService"
    Publish "OrderPlaced" (OrderPlacedPayload $a4 $ma4 $p 2)
    $dead = Wait-Until { (QueueCount "OrderPlaced.dlq") -eq 4 } 30
    Start-Sleep 2
    Check "A.4 Inventory quantity: Quantity=2 dead-lettered after one attempt" $dead "dlq=$(QueueCount 'OrderPlaced.dlq')"
    Check "A.4 Inventory quantity: logged the quantity validation error" ((Log "FlashSale.InventoryService") -match "Invalid OrderPlaced message: Quantity must be 1")
    Check "A.4 Inventory quantity: no retry lines" ((TotalRetryWarnings "FlashSale.InventoryService") -eq $warnBefore)
    Check "A.4 Inventory quantity: no Inbox row, no Outbox row, no Redis effect" ((InvInbox $ma4) -eq 0 -and (InvOutbox $a4) -eq 0 -and [int](Stock $p) -eq $stockBefore) "stock=$(Stock $p)"

    # ======================================================== B. Order StockResultConsumer
    Write-Host "== B. Order StockResultConsumer (StockReserved -> StockReserved.dlq)"
    Wait-Until { @($allQueues | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0 } 20 | Out-Null
    Stop-Svc "FlashSale.InventoryService"
    Stop-Svc "FlashSale.ProcessWorker"

    # B.1 transient: order Inbox INSERT revoked, restored after ~2 s
    $b1 = Post-Order $p ("fl-b1-" + [guid]::NewGuid()); $mb1 = [guid]::NewGuid().ToString()
    Start-Sleep 1
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    Publish "StockReserved" (StockReservedPayload $b1 $mb1 $p)
    Start-Sleep 2
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    $applied = Wait-Until { (State $b1) -eq "Confirmed" } 30
    Check "B.1 StockResult transient: applied once (Confirmed, 1 Inbox row)" ($applied -and (OrdInbox $mb1) -eq 1) "state=$(State $b1)"
    Check "B.1 StockResult transient: nothing dead-lettered" ((QueueCount "StockReserved.dlq") -eq 0) "dlq=$(QueueCount 'StockReserved.dlq')"
    Check "B.1 StockResult transient: the log shows a retry" (@($(Log "FlashSale.OrderService") -split "`r?`n" | Where-Object { $_.Contains($mb1) -and $_.Contains("retrying in") }).Count -ge 1)

    # B.2 exhausted
    Drain "StockReserved.dlq"
    Wait-Until { (QueueCount "StockReserved") -eq 0 } 20 | Out-Null
    $dlqSnap = DlqSnapshot
    $b2 = Post-Order $p ("fl-b2-" + [guid]::NewGuid()); $mb2 = [guid]::NewGuid().ToString()
    Start-Sleep 1
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    Publish "StockReserved" (StockReservedPayload $b2 $mb2 $p)
    $dead = Wait-Until { (QueueCount "StockReserved.dlq") -eq ($dlqSnap["StockReserved.dlq"] + 1) } 60
    $msg = @(DlqGet "StockReserved.dlq" 1)[0]
    Check "B.2 StockResult exhausted: retried then dead-lettered to StockReserved.dlq" $dead "dlq=$(QueueCount 'StockReserved.dlq')"
    CheckRetryLadder "FlashSale.OrderService" $mb2 "B.2 StockResult"
    Check "B.2 StockResult exhausted: x-death names source StockReserved and reason rejected" (DeathHas $msg "StockReserved" "rejected")
    $drained = Wait-Until { (QueueCount "StockReserved") -eq 0 } 15
    Check "B.2 StockResult exhausted: main queue empty (no loop)" $drained "StockReserved=$(QueueCount 'StockReserved')"
    Check "B.2 StockResult exhausted: order still PendingStock, no Inbox row" ((State $b2) -eq "PendingStock" -and (OrdInbox $mb2) -eq 0) "state=$(State $b2)"
    Check "B.2 StockResult exhausted: every other DLQ unchanged (isolation)" ((IsolationDrift $dlqSnap "StockReserved.dlq") -eq "") (IsolationDrift $dlqSnap "StockReserved.dlq")

    # B.2 replay
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    Publish "StockReserved" $msg.payload
    $done = Wait-Until { (State $b2) -eq "Confirmed" } 30
    Check "B.2 StockResult replay: applied once (Confirmed, 1 Inbox row)" ($done -and (OrdInbox $mb2) -eq 1) "state=$(State $b2)"

    # B.3 poison
    Drain "StockReserved.dlq"
    $warnBefore = TotalRetryWarnings "FlashSale.OrderService"
    Publish "StockReserved" "{not valid json"
    $dead = Wait-Until { (QueueCount "StockReserved.dlq") -eq 1 } 30
    Start-Sleep 2
    Check "B.3 StockResult poison: malformed JSON dead-lettered after one attempt" $dead "dlq=$(QueueCount 'StockReserved.dlq')"
    Check "B.3 StockResult poison: malformed JSON produced no retry lines" ((TotalRetryWarnings "FlashSale.OrderService") -eq $warnBefore)
    $b3 = Post-Order $p ("fl-b3-" + [guid]::NewGuid()); Start-Sleep 1
    Publish "StockReserved" (StockReservedPayload $b3 $empty $p)
    $dead = Wait-Until { (QueueCount "StockReserved.dlq") -eq 2 } 30
    Check "B.3 StockResult poison: empty-MessageId message dead-lettered after one attempt" $dead "dlq=$(QueueCount 'StockReserved.dlq')"
    Check "B.3 StockResult poison: empty-MessageId logged the validation error" ((Log "FlashSale.OrderService") -match "Invalid StockReserved message: MessageId is empty")
    Check "B.3 StockResult poison: no Inbox row and no state change" ((OrdInbox $empty) -eq 0 -and (State $b3) -eq "PendingStock") "state=$(State $b3)"
    Publish "StockReserved" (StockReservedPayload ([guid]::NewGuid()) $empty $p)
    $dead = Wait-Until { (QueueCount "StockReserved.dlq") -eq 3 } 30
    Check "B.3 StockResult poison: a SECOND empty-MessageId message also reaches the DLQ" $dead "dlq=$(QueueCount 'StockReserved.dlq')"

    # ======================================================== C. Order OrderProcessedConsumer
    Write-Host "== C. Order OrderProcessedConsumer (OrderProcessed -> OrderProcessed.dlq)"
    # Make a Confirmed order first (StockReserved applied with no fault).
    $c0 = Post-Order $p ("fl-c0-" + [guid]::NewGuid()); Start-Sleep 1
    Publish "StockReserved" (StockReservedPayload $c0 ([guid]::NewGuid()) $p)
    $confirmed = Wait-Until { (State $c0) -eq "Confirmed" } 30
    Check "C setup: a Confirmed order is ready for the completion tests" $confirmed "state=$(State $c0)"

    # C.1 transient
    $mc1 = [guid]::NewGuid().ToString()
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    Publish "OrderProcessed" (OrderProcessedPayload $c0 $mc1)
    Start-Sleep 2
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    $applied = Wait-Until { (State $c0) -eq "Completed" } 30
    Check "C.1 OrderProcessed transient: applied once (Completed, 1 Inbox row)" ($applied -and (OrdInbox $mc1) -eq 1) "state=$(State $c0)"
    Check "C.1 OrderProcessed transient: nothing dead-lettered" ((QueueCount "OrderProcessed.dlq") -eq 0) "dlq=$(QueueCount 'OrderProcessed.dlq')"
    Check "C.1 OrderProcessed transient: the log shows a retry" (@($(Log "FlashSale.OrderService") -split "`r?`n" | Where-Object { $_.Contains($mc1) -and $_.Contains("retrying in") }).Count -ge 1)

    # C.2 exhausted
    Drain "OrderProcessed.dlq"
    Wait-Until { (QueueCount "OrderProcessed") -eq 0 } 20 | Out-Null
    $dlqSnap = DlqSnapshot
    $c2 = Post-Order $p ("fl-c2-" + [guid]::NewGuid()); Start-Sleep 1
    Publish "StockReserved" (StockReservedPayload $c2 ([guid]::NewGuid()) $p)
    Wait-Until { (State $c2) -eq "Confirmed" } 30 | Out-Null
    $mc2 = [guid]::NewGuid().ToString()
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    Publish "OrderProcessed" (OrderProcessedPayload $c2 $mc2)
    $dead = Wait-Until { (QueueCount "OrderProcessed.dlq") -eq ($dlqSnap["OrderProcessed.dlq"] + 1) } 60
    $msg = @(DlqGet "OrderProcessed.dlq" 1)[0]
    Check "C.2 OrderProcessed exhausted: retried then dead-lettered to OrderProcessed.dlq" $dead "dlq=$(QueueCount 'OrderProcessed.dlq')"
    CheckRetryLadder "FlashSale.OrderService" $mc2 "C.2 OrderProcessed"
    Check "C.2 OrderProcessed exhausted: x-death names source OrderProcessed and reason rejected" (DeathHas $msg "OrderProcessed" "rejected")
    $drained = Wait-Until { (QueueCount "OrderProcessed") -eq 0 } 15
    Check "C.2 OrderProcessed exhausted: main queue empty (no loop)" $drained "OrderProcessed=$(QueueCount 'OrderProcessed')"
    Check "C.2 OrderProcessed exhausted: order still Confirmed, no Inbox row" ((State $c2) -eq "Confirmed" -and (OrdInbox $mc2) -eq 0) "state=$(State $c2)"
    Check "C.2 OrderProcessed exhausted: every other DLQ unchanged (isolation)" ((IsolationDrift $dlqSnap "OrderProcessed.dlq") -eq "") (IsolationDrift $dlqSnap "OrderProcessed.dlq")

    # C.2 replay
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    Publish "OrderProcessed" $msg.payload
    $done = Wait-Until { (State $c2) -eq "Completed" } 30
    Check "C.2 OrderProcessed replay: applied once (Completed, 1 Inbox row)" ($done -and (OrdInbox $mc2) -eq 1) "state=$(State $c2)"

    # C.3 poison
    Drain "OrderProcessed.dlq"
    $warnBefore = TotalRetryWarnings "FlashSale.OrderService"
    Publish "OrderProcessed" "{bad json"
    $dead = Wait-Until { (QueueCount "OrderProcessed.dlq") -eq 1 } 30
    Start-Sleep 2
    Check "C.3 OrderProcessed poison: malformed JSON dead-lettered after one attempt" $dead "dlq=$(QueueCount 'OrderProcessed.dlq')"
    Check "C.3 OrderProcessed poison: malformed JSON produced no retry lines" ((TotalRetryWarnings "FlashSale.OrderService") -eq $warnBefore)
    $c3 = Post-Order $p ("fl-c3-" + [guid]::NewGuid()); Start-Sleep 1
    Publish "StockReserved" (StockReservedPayload $c3 ([guid]::NewGuid()) $p)
    Wait-Until { (State $c3) -eq "Confirmed" } 30 | Out-Null
    Publish "OrderProcessed" (OrderProcessedPayload $c3 $empty)
    $dead = Wait-Until { (QueueCount "OrderProcessed.dlq") -eq 2 } 30
    Check "C.3 OrderProcessed poison: empty-MessageId message dead-lettered after one attempt" $dead "dlq=$(QueueCount 'OrderProcessed.dlq')"
    Check "C.3 OrderProcessed poison: empty-MessageId logged the validation error" ((Log "FlashSale.OrderService") -match "Invalid OrderProcessed message: MessageId is empty")
    Check "C.3 OrderProcessed poison: no Inbox row and no state change" ((OrdInbox $empty) -eq 0 -and (State $c3) -eq "Confirmed") "state=$(State $c3)"
    Publish "OrderProcessed" (OrderProcessedPayload ([guid]::NewGuid()) $empty)
    $dead = Wait-Until { (QueueCount "OrderProcessed.dlq") -eq 3 } 30
    Check "C.3 OrderProcessed poison: a SECOND empty-MessageId message also reaches the DLQ" $dead "dlq=$(QueueCount 'OrderProcessed.dlq')"

    # ======================================================== D. Process Worker StockReservedConsumer
    Write-Host "== D. Process Worker StockReservedConsumer (ProcessWorker.StockReserved -> ProcessWorker.StockReserved.dlq)"
    Stop-Svc "FlashSale.OrderService"
    Purge "ProcessWorker.StockReserved"
    Start-Svc "FlashSale.ProcessWorker" "worker"
    Wait-Until { (QueueCount "OrderProcessed") -ge 0 -and (QueueExists "OrderProcessed") } 30 | Out-Null

    # D.1 transient: required OrderProcessed queue missing, recreated after ~2 s
    DeleteQueue "OrderProcessed"
    $d1 = [guid]::NewGuid().ToString()
    Publish "StockReserved" (StockReservedPayload $d1 ([guid]::NewGuid()) $p)
    Start-Sleep 2
    DeclareQueue "OrderProcessed"
    $processed = Wait-Until { (LogLineCount "FlashSale.ProcessWorker" "Order $d1 processed in") -ge 1 } 40
    Start-Sleep 2
    $d1Count = LogLineCount "FlashSale.ProcessWorker" "Order $d1 processed in"
    Check "D.1 Worker transient: applied once (OrderProcessed published exactly once)" ($processed -and $d1Count -eq 1) "published=$d1Count"
    Check "D.1 Worker transient: nothing dead-lettered" ((QueueCount "ProcessWorker.StockReserved.dlq") -eq 0) "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
    Check "D.1 Worker transient: the log shows a retry" (@($(Log "FlashSale.ProcessWorker") -split "`r?`n" | Where-Object { $_.Contains($d1) -and $_.Contains("retrying in") }).Count -ge 1)

    # D.2 exhausted
    Drain "ProcessWorker.StockReserved.dlq"
    DeleteQueue "OrderProcessed"
    Wait-Until { (QueueCount "ProcessWorker.StockReserved") -eq 0 } 20 | Out-Null
    $dlqSnap = DlqSnapshot
    $d2 = [guid]::NewGuid().ToString()
    Publish "StockReserved" (StockReservedPayload $d2 ([guid]::NewGuid()) $p)
    $dead = Wait-Until { (QueueCount "ProcessWorker.StockReserved.dlq") -eq ($dlqSnap["ProcessWorker.StockReserved.dlq"] + 1) } 60
    $msg = @(DlqGet "ProcessWorker.StockReserved.dlq" 1)[0]
    Check "D.2 Worker exhausted: retried then dead-lettered to ProcessWorker.StockReserved.dlq" $dead "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
    CheckRetryLadder "FlashSale.ProcessWorker" $d2 "D.2 Worker"
    Check "D.2 Worker exhausted: x-death names source ProcessWorker.StockReserved and reason rejected" (DeathHas $msg "ProcessWorker.StockReserved" "rejected")
    $drained = Wait-Until { (QueueCount "ProcessWorker.StockReserved") -eq 0 } 15
    Check "D.2 Worker exhausted: main queue empty (no loop)" $drained "ProcessWorker.StockReserved=$(QueueCount 'ProcessWorker.StockReserved')"
    Check "D.2 Worker exhausted: every other DLQ unchanged (isolation)" ((IsolationDrift $dlqSnap "ProcessWorker.StockReserved.dlq") -eq "") (IsolationDrift $dlqSnap "ProcessWorker.StockReserved.dlq")

    # D.2 replay: recreate the queue, republish the dead letter -> published once
    DeclareQueue "OrderProcessed"
    Publish "StockReserved" $msg.payload
    $processed = Wait-Until { (LogLineCount "FlashSale.ProcessWorker" "Order $d2 processed in") -ge 1 } 40
    Start-Sleep 2
    $d2Count = LogLineCount "FlashSale.ProcessWorker" "Order $d2 processed in"
    $dlqDrained = Wait-Until { (QueueCount "ProcessWorker.StockReserved.dlq") -eq 0 } 15
    Check "D.2 Worker replay: applied once (OrderProcessed published exactly once, DLQ drained)" ($processed -and $d2Count -eq 1 -and $dlqDrained) "published=$d2Count dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"

    # D.3 poison
    Drain "ProcessWorker.StockReserved.dlq"
    $warnBefore = TotalRetryWarnings "FlashSale.ProcessWorker"
    Publish "StockReserved" "{broken json"
    $dead = Wait-Until { (QueueCount "ProcessWorker.StockReserved.dlq") -eq 1 } 30
    Start-Sleep 2
    Check "D.3 Worker poison: malformed JSON dead-lettered after one attempt" $dead "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
    Check "D.3 Worker poison: malformed JSON produced no retry lines" ((TotalRetryWarnings "FlashSale.ProcessWorker") -eq $warnBefore)
    $d3 = [guid]::NewGuid().ToString()
    Publish "StockReserved" (StockReservedPayload $d3 $empty $p)
    $dead = Wait-Until { (QueueCount "ProcessWorker.StockReserved.dlq") -eq 2 } 30
    Check "D.3 Worker poison: empty-MessageId message dead-lettered after one attempt" $dead "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
    Check "D.3 Worker poison: empty-MessageId logged the validation error" ((Log "FlashSale.ProcessWorker") -match "Invalid StockReserved message: MessageId is empty")
    Check "D.3 Worker poison: no OrderProcessed published for it" (@($(Log "FlashSale.ProcessWorker") -split "`r?`n" | Where-Object { $_.Contains("Order $d3 processed in") }).Count -eq 0)
    Publish "StockReserved" (StockReservedPayload ([guid]::NewGuid()) $empty $p)
    $dead = Wait-Until { (QueueCount "ProcessWorker.StockReserved.dlq") -eq 3 } 30
    Check "D.3 Worker poison: a SECOND empty-MessageId message also reaches the DLQ" $dead "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user; GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $proj }
    docker rm -f $mq $redis *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Retries are bounded; poison and exhausted messages land in the correct service DLQ and replay applies once." -ForegroundColor Green
