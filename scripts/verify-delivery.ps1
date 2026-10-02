# ============================================================
# Week 9 TP-M01 (docs/delivery-semantics.md): each consumer's Inbox
# uniqueness and local transaction, and a crash after commit but before ack
# causes a safe replay.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-delivery.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ and Redis against the given PostgreSQL container.
#   Uniqueness: unique MessageId index in both Inbox tables; a duplicate insert
#               as each service's own account fails with 23505.
#   Local transaction: Inbox INSERT revoked -> the business write rolls back with
#               it, the message is dead-lettered, and a replay applies it once.
#   Crash: for each of the four consumers, FaultInjection kills the process
#          after its commit and before its ack; after a restart the same
#          message is redelivered and treated as already processed.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-dl-mq"; $amqp = 5688; $mgmt = 15688; $redis = "verify-dl-redis"; $redisPort = 6397
$orderPort = 5124; $invPort = 5125; $workerPort = 5126
$ex = "flashsale.order.exchange"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}   # project -> current log file

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql, [string]$user = "flashsale") {
    $out = $sql | docker exec -i $Container psql -U $user -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 5 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function QueueCount([string]$q) { $r = Mq Get "/queues/%2F/$q"; if ($r) { return [int]$r.messages } else { return -1 } }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis([string[]]$cmd) { return (docker exec $redis redis-cli @cmd | Out-String).Trim() }
function Log([string]$project) {
    $fs = New-Object IO.FileStream($logs[$project], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Running([string]$project) { return @(Get-CimInstance Win32_Process -Filter "Name='$project.exe'").Count -gt 0 }
function Stop-Svc([string]$project) {
    Get-CimInstance Win32_Process -Filter "Name='$project.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Wait-Until { -not (Running $project) } 20 | Out-Null
}
# Starts a service with its own new log file. $crash = @(consumer, correlationId) turns on the fault.
function Start-Svc([string]$project, [string]$tag, [string[]]$crash = @()) {
    $envs = @{} + $svcEnv[$project]
    if ($crash.Count -eq 2) { $envs["FaultInjection__CrashBeforeAckConsumer"] = $crash[0]; $envs["FaultInjection__CrashBeforeAckCorrelationId"] = $crash[1] }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-dl-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "dl-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function Ts([string]$id, [string]$col) { return (Sql "SELECT coalesce(to_char(`"$col`", 'YYYY-MM-DD HH24:MI:SS.US'), '-') FROM order_service.orders WHERE `"Id`" = '$id';") }
function PlacedMsg([string]$id) { return (Sql "SELECT `"Payload`"->>'MessageId' FROM order_service.outbox_events WHERE `"Payload`"->>'OrderId' = '$id';") }
function ResultMsg([string]$id) { return (Sql "SELECT `"Payload`"->>'MessageId' FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id';") }
function InvInbox([string]$msg) { if (-not $msg) { return -1 }; return [int](Sql "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function OrdInbox([string]$msg) { if (-not $msg) { return -1 }; return [int](Sql "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvOutbox([string]$id) { return [int](Sql "SELECT count(*) FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id';") }
function Replay([string]$dlq, [string]$routingKey) {
    $msgs = @(Mq Post "/queues/%2F/$dlq/get" @{ count = 10; ackmode = "ack_requeue_false"; encoding = "auto" } | ForEach-Object { $_ })
    foreach ($m in $msgs) { Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $routingKey; content_type = "application/json" }; routing_key = $routingKey; payload = $m.payload; payload_encoding = "string" } | Out-Null }
    return $msgs.Count
}

$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "dl-$runId"
try {
    # ---------------------------------------------------------- Inbox uniqueness
    Write-Host "== Inbox uniqueness"
    foreach ($s in @(@("order_service", "order_service_user"), @("inventory_service", "inventory_service_user"))) {
        $idx = Sql "SELECT indexdef FROM pg_indexes WHERE schemaname = '$($s[0])' AND tablename = 'processed_messages' AND indexdef LIKE 'CREATE UNIQUE INDEX%(`"MessageId`")';"
        Check "$($s[0]).processed_messages has a unique index on MessageId" ($idx -ne "") $idx
        $m = [guid]::NewGuid()
        $out = Sql "BEGIN; INSERT INTO $($s[0]).processed_messages VALUES ('$([guid]::NewGuid())', '$m', 'Probe', now()); INSERT INTO $($s[0]).processed_messages VALUES ('$([guid]::NewGuid())', '$m', 'Probe', now()); ROLLBACK;" $s[1]
        Check "a second Inbox row with the same MessageId is refused for $($s[1]) (unique violation)" ($out -match "duplicate key value violates unique constraint" -and $out -match "IX_processed_messages_MessageId") $out
    }

    # ---------------------------------------------------------- stack
    docker rm -f $mq $redis *> $null
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-dl-definitions.json"; $conf = Join-Path $env:TEMP "verify-dl-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $hash = [Convert]::ToBase64String($salt + [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev")))
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(@{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
    } | ConvertTo-Json -Depth 5 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Start-Svc $proj "start" }
    $queues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed", "ProcessWorker.StockReserved"
    $ready = Wait-Until { @($queues | Where-Object { $null -eq (Mq Get "/queues/%2F/$_") }).Count -eq 0 } 120
    Check "all three services up; all five consumer queues declared" $ready
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 10 } -Force *> $null
    Check "warm-up: $p has 10 units" ((Redis "GET", "inventory:$p") -eq "10")

    # ---------------------------------------------------------- local transaction: Inventory
    Write-Host "== Local transaction"
    $dlqBefore = QueueCount "OrderPlaced.dlq"
    Sql "REVOKE INSERT ON inventory_service.processed_messages FROM inventory_service_user;" | Out-Null
    $o1 = Post-Order $p ("dl-tx-inv-" + [guid]::NewGuid())
    $dead = Wait-Until { (QueueCount "OrderPlaced.dlq") -eq ($dlqBefore + 1) } 60
    $m1 = PlacedMsg $o1
    Check "Inventory, Inbox refused: retried then dead-lettered" $dead
    Check "Inventory, Inbox refused: the result Outbox row rolled back with it (no row, no Inbox row)" ((InvOutbox $o1) -eq 0 -and (InvInbox $m1) -eq 0 -and (State $o1) -eq "PendingStock")
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user;" | Out-Null
    $n = Replay "OrderPlaced.dlq" "OrderPlaced"
    $done = Wait-Until { (State $o1) -eq "Completed" } 60
    Check "Inventory: after the fault, replaying the dead letter applies it once (Completed, 1 Outbox row, 1 Inbox row, 1 unit taken)" (
        $n -eq 1 -and $done -and (InvOutbox $o1) -eq 1 -and (InvInbox $m1) -eq 1 -and (Redis "GET", "inventory:$p") -eq "9") "replayed=$n state=$(State $o1) stock=$(Redis 'GET', "inventory:$p")"

    # ---------------------------------------------------------- local transaction: Order Service
    $srBefore = QueueCount "StockReserved.dlq"; $opBefore = QueueCount "OrderProcessed.dlq"
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $o2 = Post-Order $p ("dl-tx-ord-" + [guid]::NewGuid())
    $dead = Wait-Until { (QueueCount "StockReserved.dlq") -eq ($srBefore + 1) } 60
    $r2 = ResultMsg $o2
    Check "Order Service, Inbox refused: StockReserved retried then dead-lettered" $dead
    Check "Order Service, Inbox refused: the state change rolled back with it (PendingStock, no Inbox row)" ((State $o2) -eq "PendingStock" -and (OrdInbox $r2) -eq 0 -and (Ts $o2 "ConfirmedOrRejectedAt") -eq "-")
    # The Process Worker's OrderProcessed reaches a PendingStock order and is
    # dead-lettered: the known Week 9/11 gap (docs/design-decisions.md).
    Wait-Until { (QueueCount "OrderProcessed.dlq") -eq ($opBefore + 1) } 30 | Out-Null
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    $n = Replay "StockReserved.dlq" "StockReserved"
    $ok = Wait-Until { (State $o2) -eq "Confirmed" } 30
    $n2 = Replay "OrderProcessed.dlq" "OrderProcessed"
    $done = Wait-Until { (State $o2) -eq "Completed" } 30
    Check "Order Service: after the fault, replaying the dead letters applies each once (Confirmed then Completed, 1 Inbox row each)" (
        $n -eq 1 -and $ok -and $done -and (OrdInbox $r2) -eq 1 -and (OrdInbox $o2) -eq 1) "replayed=$n/$n2 state=$(State $o2)"

    # ---------------------------------------------------------- crash after commit, before ack
    Write-Host "== Crash after commit, before ack"

    # 1. Inventory OrderPlaced
    $k = "dl-crash-inv-" + [guid]::NewGuid()
    Stop-Svc "FlashSale.InventoryService"; Start-Svc "FlashSale.InventoryService" "crash" @("OrderPlaced", $k)
    $stock = [int](Redis "GET", "inventory:$p")
    $o3 = Post-Order $p $k
    $died = Wait-Until { -not (Running "FlashSale.InventoryService") } 40
    $m3 = PlacedMsg $o3
    Check "Inventory crash: the process was killed after its commit (fault log line, process gone)" ($died -and (Log "FlashSale.InventoryService") -match "Fault injection: OrderPlaced committed")
    Check "Inventory crash: work committed before the crash (1 Inbox row, 1 Outbox row, 1 unit taken)" ((InvInbox $m3) -eq 1 -and (InvOutbox $o3) -eq 1 -and [int](Redis "GET", "inventory:$p") -eq $stock - 1)
    Check "Inventory crash: the unacknowledged OrderPlaced is back in its queue" (Wait-Until { (QueueCount "OrderPlaced") -eq 1 } 20) "OrderPlaced=$(QueueCount 'OrderPlaced')"
    Start-Svc "FlashSale.InventoryService" "restart"
    $done = Wait-Until { (State $o3) -eq "Completed" } 60
    Check "Inventory replay: the same MessageId was redelivered and acked as already processed" ((Log "FlashSale.InventoryService") -match "OrderPlaced $m3 for order $o3 already processed")
    Check "Inventory replay: one effect (Completed, 1 Inbox row, 1 Outbox row, still exactly 1 unit taken)" ($done -and (InvInbox $m3) -eq 1 -and (InvOutbox $o3) -eq 1 -and [int](Redis "GET", "inventory:$p") -eq $stock - 1)

    # 2. Order Service StockResult
    $k = "dl-crash-sr-" + [guid]::NewGuid()
    Stop-Svc "FlashSale.OrderService"; Start-Svc "FlashSale.OrderService" "crash-sr" @("StockResult", $k)
    $o4 = Post-Order $p $k
    $died = Wait-Until { -not (Running "FlashSale.OrderService") } 40
    $r4 = ResultMsg $o4; $decided = Ts $o4 "ConfirmedOrRejectedAt"
    Check "StockResult crash: the process was killed after its commit" ($died -and (Log "FlashSale.OrderService") -match "Fault injection: StockResult committed")
    Check "StockResult crash: Confirmed and 1 Inbox row committed before the crash" ((State $o4) -eq "Confirmed" -and (OrdInbox $r4) -eq 1 -and $decided -ne "-")
    Check "StockResult crash: the unacknowledged StockReserved is back in its queue" (Wait-Until { (QueueCount "StockReserved") -eq 1 } 20) "StockReserved=$(QueueCount 'StockReserved')"
    Start-Svc "FlashSale.OrderService" "restart-sr"
    $done = Wait-Until { (State $o4) -eq "Completed" } 60
    Check "StockResult replay: the same MessageId was redelivered and acked as already processed" ((Log "FlashSale.OrderService") -match "StockReserved $r4 for order $o4 already processed")
    Check "StockResult replay: one effect (1 Inbox row, decision timestamp unchanged, then Completed)" ($done -and (OrdInbox $r4) -eq 1 -and (Ts $o4 "ConfirmedOrRejectedAt") -eq $decided)

    # 3. Order Service OrderProcessed
    $k = "dl-crash-op-" + [guid]::NewGuid()
    Stop-Svc "FlashSale.OrderService"; Start-Svc "FlashSale.OrderService" "crash-op" @("OrderProcessed", $k)
    $o5 = Post-Order $p $k
    $died = Wait-Until { -not (Running "FlashSale.OrderService") } 40
    $completed = Ts $o5 "CompletedAt"
    Check "OrderProcessed crash: the process was killed after its commit" ($died -and (Log "FlashSale.OrderService") -match "Fault injection: OrderProcessed committed")
    Check "OrderProcessed crash: Completed and 1 Inbox row committed before the crash" ((State $o5) -eq "Completed" -and (OrdInbox $o5) -eq 1 -and $completed -ne "-")
    Check "OrderProcessed crash: the unacknowledged OrderProcessed is back in its queue" (Wait-Until { (QueueCount "OrderProcessed") -eq 1 } 20) "OrderProcessed=$(QueueCount 'OrderProcessed')"
    Start-Svc "FlashSale.OrderService" "restart-op"
    $acked = Wait-Until { (Log "FlashSale.OrderService") -match "OrderProcessed $o5 for order $o5 already processed" } 30
    Check "OrderProcessed replay: the same MessageId was redelivered and acked as already processed" $acked
    Check "OrderProcessed replay: one effect (1 Inbox row, completion timestamp unchanged)" ((OrdInbox $o5) -eq 1 -and (Ts $o5 "CompletedAt") -eq $completed -and (State $o5) -eq "Completed")

    # 4. Process Worker
    $k = "dl-crash-pw-" + [guid]::NewGuid()
    Stop-Svc "FlashSale.ProcessWorker"; Start-Svc "FlashSale.ProcessWorker" "crash" @("ProcessWorker", $k)
    $o6 = Post-Order $p $k
    $died = Wait-Until { -not (Running "FlashSale.ProcessWorker") } 40
    $done = Wait-Until { (State $o6) -eq "Completed" } 30
    $completed = Ts $o6 "CompletedAt"
    Check "Process Worker crash: killed after its confirmed publish of OrderProcessed" ($died -and (Log "FlashSale.ProcessWorker") -match "Order $o6 processed in" -and (Log "FlashSale.ProcessWorker") -match "Fault injection: ProcessWorker committed")
    Check "Process Worker crash: the order was completed once by that publish" ($done -and (OrdInbox $o6) -eq 1)
    Check "Process Worker crash: the unacknowledged StockReserved is back in its queue" (Wait-Until { (QueueCount "ProcessWorker.StockReserved") -eq 1 } 20) "ProcessWorker.StockReserved=$(QueueCount 'ProcessWorker.StockReserved')"
    Start-Svc "FlashSale.ProcessWorker" "restart"
    $again = Wait-Until { (Log "FlashSale.ProcessWorker") -match "Order $o6 processed in" } 30
    $absorbed = Wait-Until { (Log "FlashSale.OrderService") -match "OrderProcessed $o6 for order $o6 already processed" } 30
    Check "Process Worker replay: StockReserved redelivered, OrderProcessed published again with the same MessageId" $again
    Check "Process Worker replay: Order Service absorbed the copy (already processed; 1 Inbox row; completion timestamp unchanged)" ($absorbed -and (OrdInbox $o6) -eq 1 -and (Ts $o6 "CompletedAt") -eq $completed)

    # ---------------------------------------------------------- end state
    Check "stock for ${p}: 10 - 6 orders = 4, and Redis recorded exactly those 6 orders" ((Redis "GET", "inventory:$p") -eq "4" -and (Redis "SCARD", "processed:$p") -eq "6")
    $all = $queues + @($queues | ForEach-Object { "$_.dlq" })
    $empty = Wait-Until { @($all | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0 } 20
    Check "every queue and every DLQ is empty at the end" $empty (($all | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user; GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $proj }
    docker rm -f $mq $redis *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Every consumer's Inbox is unique and transactional; a crash after commit and before ack replays safely." -ForegroundColor Green
