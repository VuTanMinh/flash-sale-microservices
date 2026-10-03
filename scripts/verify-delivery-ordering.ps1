# ============================================================
# Week 9 TP-M02 (docs/delivery-semantics.md, docs/design-decisions.md §2):
# concurrent duplicates, duplicate business events with a new MessageId, and
# late/out-of-order completion -- one stock deduction, one applied business
# result.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-delivery-ordering.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service (and, where the case needs it, Inventory Service and the
# Process Worker) on a throwaway RabbitMQ (5689/15689) and Redis (6398) against
# the given PostgreSQL container.
#
#   1. Concurrent duplicates: the SAME StockReserved MessageId delivered 8x at
#      once, and 8 concurrent deliveries with 8 DIFFERENT MessageIds. Applied
#      once; every other copy accounted for; none dead-lettered.
#   2. Duplicate business event, new MessageId: the real OrderPlaced re-published
#      (what ReconciliationWorker does) -> Redis DUPLICATE, no second deduction,
#      no second result Outbox row; the real StockReserved re-published -> no-op.
#   3. Out-of-order completion: OrderProcessed for a PendingStock order must be
#      requeued, not dead-lettered, and applied once StockReserved lands; with no
#      StockReserved it must be bounded (requeues then DLQ); a stale StockReserved
#      after Completed must stay a no-op.
#
# Three deliberate choices about which services run, and why:
#
#   * Order Service and Inventory Service are started from the beginning. A
#     service's outbox publisher refuses to publish to a configured required
#     subscriber queue that does not exist (docs/outbox.md, Week 6 routed
#     confirmation), and one of Inventory Service's required subscribers for
#     StockReserved is the Process Worker's ProcessWorker.StockReserved. Because
#     the Worker is not started until case 3, the script pre-declares that queue
#     (and its DLQ) in the RabbitMQ definitions below, with no consumer, so
#     Inventory can publish StockReserved while no Worker is consuming it.
#   * The Process Worker is started only after case 1, because case 3(a) wants an
#     order that is still PendingStock when an OrderProcessed arrives; a running
#     Worker would confirm the order first.
#   * For case 1 the forged StockReserved messages are the only ones that may
#     reach Order Service, so Inventory Service's INSERT on its own Inbox is
#     revoked for that window: its OrderPlaced retries and dead-letters instead
#     of publishing a real stock result that would conflict with what the case
#     is measuring. The grant is restored before case 2, and again in `finally`.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-do-mq"; $amqp = 5689; $mgmt = 15689; $redis = "verify-do-redis"; $redisPort = 6398
$orderPort = 5129; $invPort = 5130; $workerPort = 5131
$ex = "flashsale.order.exchange"
$dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}          # project -> current log file
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "do-$runId"                 # warmed product, used by every real order
$pForged = "do-forged-$runId"    # never warmed: forged StockReserved only
$servicePorts = 5129, 5130, 5131
$retryQueues = "OrderProcessed.retry.1", "OrderProcessed.retry.2", "OrderProcessed.retry.3"

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql, [string]$user = "flashsale") {
    $out = $sql | docker exec -i $Container psql -U $user -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql, [string]$user = "flashsale") { return [int](Sql $sql $user) }
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 5 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
# Queue counts come back as -1 when the queue does not exist yet, which must
# never be mistaken for "empty" (AGENTS.md Part A5: no check passes by default).
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
    $log = Join-Path $env:TEMP "verify-do-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "do-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function Ts([string]$id, [string]$col) { return (Sql "SELECT coalesce(to_char(`"$col`", 'YYYY-MM-DD HH24:MI:SS.US'), '-') FROM order_service.orders WHERE `"Id`" = '$id';") }
function OrdInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvOutbox([string]$id) { return (Int1 "SELECT count(*) FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id';") }
function PlacedPayload([string]$id) { return (Sql "SELECT `"Payload`"::text FROM order_service.outbox_events WHERE `"Payload`"->>'OrderId' = '$id' ORDER BY `"CreatedAt`" LIMIT 1;") }
function ResultPayload([string]$id) { return (Sql "SELECT `"Payload`"::text FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id' LIMIT 1;") }
function ResultMessageId([string]$id) { return (Sql "SELECT `"Payload`"->>'MessageId' FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id' LIMIT 1;") }
function Stock([string]$product) { return (Redis "GET", "inventory:$product") }
function Publish([string]$eventType, [string]$payload) {
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $eventType; content_type = "application/json" }; routing_key = $eventType; payload = $payload; payload_encoding = "string" } | Out-Null
}
function StockReservedPayload([string]$orderId, [string]$messageId, [string]$productId) {
    return "{`"OrderId`":`"$orderId`",`"ProductId`":`"$productId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-delivery-ordering`"}"
}
# OrderProcessed.MessageId is the OrderId (docs/design-decisions.md section 1),
# which makes the crafted message byte-identical to the Worker's own.
function OrderProcessedPayload([string]$orderId) {
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$orderId`",`"CorrelationId`":`"verify-delivery-ordering`"}"
}
# N processes publishing at once. Returns the number that reported success.
# Background jobs are separate PowerShell processes: a native call under
# $ErrorActionPreference="Stop" would throw on stderr, and the *> $null plus a
# redirect inside the job keeps the child's output away from PowerShell's own
# stderr stream (AGENTS.md Part E pitfalls). Start-Job is also why this script
# can run where `dotnet test` cannot: the vstest test host talks to its parent
# over a named pipe, while a background job is a normal child process.
function Publish-Parallel([string]$eventType, [string[]]$payloads) {
    $jobs = @()
    for ($i = 0; $i -lt $payloads.Count; $i++) {
        $payload = $payloads[$i]
        $jobs += Start-Job -ScriptBlock {
            param($Mgmt, $Exchange, $Type, $Payload)
            try {
                $body = @{ properties = @{ type = $Type; content_type = "application/json" }; routing_key = $Type; payload = $Payload; payload_encoding = "string" } | ConvertTo-Json -Depth 5 -Compress
                $bytes = [Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")
                $hdr = @{ Authorization = "Basic " + [Convert]::ToBase64String($bytes) }
                Invoke-RestMethod -Method Post -Headers $hdr -ContentType "application/json" -Body $body -Uri "http://localhost:$Mgmt/api/exchanges/%2F/$Exchange/publish" -TimeoutSec 20 | Out-Null
                return "ok"
            } catch { return "fail" }
        } -ArgumentList $mgmt, $ex, $eventType, $payload
    }
    $null = Wait-Job -Job $jobs -Timeout 60
    $done = @($jobs | Receive-Job)
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    return @($done | Where-Object { $_ -eq "ok" }).Count
}

try {
    # ---------------------------------------------------------- guards
    Write-Host "== Environment"
    # Fail fast and explicitly when Docker is not answering, rather than letting
    # every later `docker exec` return an empty string that a Check could read as
    # a real value (Part A5: a check must never pass by default).
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $servicePorts) {
        $used = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0
        if ($used) { throw "port $port is already in use; this script needs 5129-5131" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-do-definitions.json"; $conf = Join-Path $env:TEMP "verify-do-rabbitmq.conf"
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
        # ProcessWorker.StockReserved is declared here, with no consumer, and with
        # exactly the arguments the Process Worker declares for it (so the Worker's
        # own QueueDeclareAsync later is a no-op rather than a PRECONDITION_FAILED).
        # Inventory Service's outbox publisher refuses to publish StockReserved
        # until every required subscriber queue exists (routed confirmation), and
        # this queue is one of them -- declaring it up front is what lets the normal
        # flow settle before the Worker is ever started.
        queues = @(
            @{ name = "ProcessWorker.StockReserved"; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{ "x-dead-letter-exchange" = $dlx; "x-dead-letter-routing-key" = "ProcessWorker.StockReserved" } }
            @{ name = "ProcessWorker.StockReserved.dlq"; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} }
        )
        bindings = @(
            @{ source = $ex; vhost = "/"; destination = "ProcessWorker.StockReserved"; destination_type = "queue"; routing_key = "StockReserved"; arguments = @{} }
            @{ source = $dlx; vhost = "/"; destination = "ProcessWorker.StockReserved.dlq"; destination_type = "queue"; routing_key = "ProcessWorker.StockReserved"; arguments = @{} }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    Start-Svc "FlashSale.OrderService" "start"
    Start-Svc "FlashSale.InventoryService" "start"
    # Only the queues the two *running* services declare, in this start order:
    # OrderPlaced is declared by Inventory Service's OrderPlacedConsumer,
    # StockReserved and StockRejected by Order Service's StockResultConsumer, and
    # OrderProcessed (plus the retry queues checked below) by Order Service's
    # OrderProcessedConsumer. ProcessWorker.StockReserved is deliberately NOT in
    # this list: it is declared by the Process Worker, which this script starts
    # only in case 3, so waiting for it here is what made the first version of
    # this script fail its readiness check even though both services were up. It
    # is instead pre-declared in the RabbitMQ definitions above, with no
    # consumer, so Inventory Service's outbox publisher sees it and publishes
    # StockReserved while the Worker is still absent.
    $queues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed"
    $ready = Wait-Until { @($queues | Where-Object { -not (QueueExists $_) }).Count -eq 0 } 120
    Check "Order Service and Inventory Service are up; every run queue they declare exists" $ready (($queues | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    Check "ProcessWorker.StockReserved is pre-declared (no consumer) so Inventory can publish StockReserved while the Worker is absent" (QueueExists "ProcessWorker.StockReserved")
    Check "the three delayed retry queues are declared alongside OrderProcessed" (
        @($retryQueues | Where-Object { -not (QueueExists $_) }).Count -eq 0) (($retryQueues | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # The retry queues must be BOUND to the dead-letter exchange: the consumer
    # republishes to that exchange with the queue name as routing key, so an
    # unbound queue makes every requeue unroutable.
    $bindings = @(Mq Get "/exchanges/%2F/$dlx/bindings/source")
    foreach ($rq in $retryQueues) {
        Check "retry queue $rq is bound to $dlx with its own name as routing key" (
            @($bindings | Where-Object { $_.destination -eq $rq -and $_.routing_key -eq $rq }).Count -eq 1)
    }

    $t1 = [int]((Mq Get "/queues/%2F/OrderProcessed.retry.1").arguments.'x-message-ttl')
    $t2 = [int]((Mq Get "/queues/%2F/OrderProcessed.retry.2").arguments.'x-message-ttl')
    $t3 = [int]((Mq Get "/queues/%2F/OrderProcessed.retry.3").arguments.'x-message-ttl')
    Check "retry queues carry the 2s/4s/8s requeue ladder" ($t1 -eq 2000 -and $t2 -eq 4000 -and $t3 -eq 8000) "$t1/$t2/$t3"
    Check "retry queues dead-letter back with routing key OrderProcessed" (
        ((Mq Get "/queues/%2F/OrderProcessed.retry.1").arguments.'x-dead-letter-routing-key') -eq "OrderProcessed")

    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 30 } -Force *> $null
    Check "warm-up: $p has 30 units" ((Stock $p) -eq "30")

    # ======================================================== 1. concurrent duplicates
    Write-Host "== 1. Concurrent duplicates (same message, at once)"

    # Only the forged copies may reach Order Service in this case, so Inventory's
    # own Inbox insert is refused: its OrderPlaced retries and dead-letters
    # (into OrderPlaced.dlq) rather than publishing a real stock result that
    # would conflict with what these checks measure. Nothing is acked that was
    # not applied, and the grant is restored before case 2.
    Sql "REVOKE INSERT ON inventory_service.processed_messages FROM inventory_service_user;" | Out-Null
    $placedDlqBefore = QueueCount "OrderPlaced.dlq"
    $srDlqBefore = QueueCount "StockReserved.dlq"
    $strDlqBefore = QueueCount "StockRejected.dlq"
    $stockBefore = Stock $p

    # (a) one MessageId, 8 simultaneous deliveries. All eight race past the
    # Inbox check together, so this is the unique-violation path, not just the
    # AnyAsync shortcut.
    $o1 = Post-Order $pForged ("do-conc-a-" + [guid]::NewGuid())
    Start-Sleep 3   # let the API commit and the Outbox publish OrderPlaced
    $forgedMsg = [guid]::NewGuid()
    $sent = Publish-Parallel "StockReserved" (@($forgedMsg) * 8 | ForEach-Object { StockReservedPayload $o1 $_ $pForged })
    $applied = Wait-Until { (State $o1) -eq "Confirmed" } 40
    Start-Sleep 5   # let every loser finish (each is a no-op or a refused insert)
    Check "8 simultaneous deliveries of the same StockReserved published" ($sent -eq 8) "published=$sent"
    Check "same MessageId, 8 at once: the order is Confirmed exactly once" ($applied -and (State $o1) -eq "Confirmed") "state=$(State $o1)"
    Check "same MessageId, 8 at once: exactly one Inbox row for that message" ((OrdInbox $forgedMsg) -eq 1) "rows=$(OrdInbox $forgedMsg)"
    Check "same MessageId, 8 at once: no copy is dead-lettered" ((QueueCount "StockReserved.dlq") -eq $srDlqBefore) "dlq=$(QueueCount 'StockReserved.dlq') before=$srDlqBefore"

    # (b) 8 DIFFERENT MessageIds, all claiming the same StockReserved.
    $o2 = Post-Order $pForged ("do-conc-b-" + [guid]::NewGuid())
    Start-Sleep 3
    $distinct = @(1..8 | ForEach-Object { [guid]::NewGuid() })
    $sent = Publish-Parallel "StockReserved" @($distinct | ForEach-Object { StockReservedPayload $o2 $_ $pForged })
    $applied = Wait-Until { (State $o2) -eq "Confirmed" } 40
    Start-Sleep 5
    $recorded = 0
    foreach ($m in $distinct) { $recorded += (OrdInbox $m) }
    Check "8 simultaneous deliveries with 8 different MessageIds published" ($sent -eq 8) "published=$sent"
    Check "different MessageIds, same fact: the order is Confirmed exactly once" ($applied -and (State $o2) -eq "Confirmed") "state=$(State $o2)"
    Check "different MessageIds, same fact: every copy is accounted for in the Inbox (8 rows)" ($recorded -eq 8) "rows=$recorded"
    Check "different MessageIds, same fact: no copy is dead-lettered" ((QueueCount "StockReserved.dlq") -eq $srDlqBefore) "dlq=$(QueueCount 'StockReserved.dlq')"
    Check "a concurrent duplicate never re-stamps the decision time" (((Ts $o1 "ConfirmedOrRejectedAt") -ne "-") -and ((Ts $o2 "ConfirmedOrRejectedAt") -ne "-"))

    # The forged copies never reach Redis, so none of case 1 may touch stock.
    Check "case 1 (both concurrent cases together) moved no stock and reserved nothing" (
        (Stock $p) -eq $stockBefore -and (Redis "SCARD", "processed:$p") -eq "0") "stock=$(Stock $p) reserved=$(Redis 'SCARD', "processed:$p")"

    # Restore Inventory and let the suppressed OrderPlaced messages finish
    # dead-lettering before case 2 starts, so case 2 cannot race them.
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user;" | Out-Null
    $suppressed = Wait-Until { (QueueCount "OrderPlaced.dlq") -ge ($placedDlqBefore + 2) } 60
    Check "the two suppressed OrderPlaced messages were retried then dead-lettered, not acked unprocessed" $suppressed "OrderPlaced.dlq=$(QueueCount 'OrderPlaced.dlq') before=$placedDlqBefore"

    # ======================================================== 2. normal flow + new MessageId
    Write-Host "== 2. Duplicate business event with a new MessageId"

    $o3 = Post-Order $p ("do-main-" + [guid]::NewGuid())
    $confirmed = Wait-Until { (State $o3) -eq "Confirmed" } 60
    $placed = PlacedPayload $o3
    $origObj = $placed | ConvertFrom-Json
    Check "normal flow: the order is Confirmed through the real Inventory consumer, one unit deducted" (
        $confirmed -and (Stock $p) -eq "29") "state=$(State $o3) stock=$(Stock $p)"
    Check "normal flow: the result is a StockReserved with an Inbox row at Inventory" (
        (InvInbox "$($origObj.MessageId)") -eq 1 -and (ResultPayload $o3) -match '"MessageId"') "inbox=$(InvInbox "$($origObj.MessageId)")"

    # (a) what ReconciliationWorker does: the same OrderPlaced again, new MessageId.
    $newPlacedMsg = ([guid]::NewGuid()).ToString()
    $repubObj = $placed | ConvertFrom-Json
    $repubObj.MessageId = $newPlacedMsg
    $placedAgain = $repubObj | ConvertTo-Json -Compress
    $placedAgainObj = $placedAgain | ConvertFrom-Json
    Check "the re-published OrderPlaced is the committed payload with only MessageId changed" (
        ($placed -ne "") -and
        ($origObj.OrderId -eq $placedAgainObj.OrderId) -and
        ($origObj.ProductId -eq $placedAgainObj.ProductId) -and
        ($origObj.Quantity -eq $placedAgainObj.Quantity) -and
        ($origObj.CorrelationId -eq $placedAgainObj.CorrelationId) -and
        ($origObj.MessageId -ne $placedAgainObj.MessageId) -and
        ($placedAgainObj.MessageId -eq $newPlacedMsg)) "original=$placed"
    $stockBefore = Stock $p
    $stateBeforeA = State $o3; $decidedBeforeA = Ts $o3 "ConfirmedOrRejectedAt"
    Publish "OrderPlaced" $placedAgain
    $dupSeen = Wait-Until { (InvInbox $newPlacedMsg) -eq 1 } 40
    Start-Sleep 3
    Check "re-published OrderPlaced: Redis answered DUPLICATE, so no second unit was deducted" (
        $dupSeen -and (Stock $p) -eq $stockBefore -and (Redis "SCARD", "processed:$p") -eq "1") "stock=$stockBefore -> $(Stock $p), reserved=$(Redis 'SCARD', "processed:$p")"
    Check "re-published OrderPlaced: no second result Outbox row" ((InvOutbox $o3) -eq 1) "rows=$(InvOutbox $o3)"
    Check "re-published OrderPlaced: the order state and timestamps are unchanged" (
        (State $o3) -eq $stateBeforeA -and (Ts $o3 "ConfirmedOrRejectedAt") -eq $decidedBeforeA) "state=$(State $o3)"

    # (b) the real StockReserved again with a new MessageId: a no-op on the order.
    $newReservedMsg = [guid]::NewGuid()
    Publish "StockReserved" (StockReservedPayload $o3 $newReservedMsg $p)
    $noopSeen = Wait-Until { (OrdInbox $newReservedMsg) -eq 1 } 30
    Start-Sleep 3
    Check "duplicate StockReserved with a new MessageId: recorded as a no-op, state and timestamps unchanged" (
        $noopSeen -and (State $o3) -eq $stateBeforeA -and (Ts $o3 "ConfirmedOrRejectedAt") -eq $decidedBeforeA) "state=$(State $o3) inbox=$(OrdInbox $newReservedMsg)"
    Check "duplicate StockReserved is not dead-lettered" ((QueueCount "StockReserved.dlq") -eq $srDlqBefore) "dlq=$(QueueCount 'StockReserved.dlq')"

    # ======================================================== 3. late / out-of-order completion
    Write-Host "== 3. Late and out-of-order completion"

    # (a) OrderProcessed while the order is still PendingStock. The Worker is
    # still stopped, and Order Service's own Inbox insert is refused so its
    # StockReserved consumer cannot confirm the order before the crafted
    # completion arrives -- that is what guarantees the early path is exercised
    # instead of racing it. The grant is restored as soon as the requeue is
    # observed; the consumer then applies the stock result on its next retry
    # (in-process ladder 1 s / 2 s / 4 s) and the requeued completion applies.
    $opDlqBefore = QueueCount "OrderProcessed.dlq"
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $o4 = Post-Order $p ("do-early-" + [guid]::NewGuid())
    $earlyMsg = $o4     # OrderProcessed.MessageId is the OrderId
    Publish "OrderProcessed" (OrderProcessedPayload $o4)
    $queued = Wait-Until { (QueueCount "OrderProcessed.retry.1") -ge 1 } 30
    $stillPending = (State $o4) -eq "PendingStock"
    $notRecorded = (OrdInbox $earlyMsg) -eq 0
    $notDead = (QueueCount "OrderProcessed.dlq") -eq $opDlqBefore
    Check "early OrderProcessed is requeued onto a delayed retry queue (the requeue is routable)" $queued "retry.1=$(QueueCount 'OrderProcessed.retry.1')"
    Check "early OrderProcessed is NOT dead-lettered" $notDead "dlq=$(QueueCount 'OrderProcessed.dlq') before=$opDlqBefore"
    Check "early OrderProcessed writes no Inbox row while it is unapplied" $notRecorded "rows=$(OrdInbox $earlyMsg)"
    Check "early OrderProcessed leaves the order alone (still PendingStock, no completion time)" ($stillPending -and (Ts $o4 "CompletedAt") -eq "-") "state=$(State $o4) completed=$(Ts $o4 'CompletedAt')"
    Check "the Order Service logged the requeue, not a state conflict" (
        (Log "FlashSale.OrderService") -match "OrderProcessed $earlyMsg for order $o4 arrived before its StockReserved")

    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    Start-Svc "FlashSale.ProcessWorker" "late"
    $completed = Wait-Until { (State $o4) -eq "Completed" } 90
    $completedTs = Ts $o4 "CompletedAt"
    Start-Sleep 8   # let any remaining requeued copy come back and be acked
    Check "once StockReserved lands the requeued completion applies: the order reaches Completed" $completed "state=$(State $o4)"
    Check "the same completion is applied exactly once (one Inbox row, one completion stamp)" (
        (OrdInbox $earlyMsg) -eq 1 -and $completedTs -ne "-" -and (Ts $o4 "CompletedAt") -eq $completedTs) "rows=$(OrdInbox $earlyMsg) completed=$completedTs"
    Check "the early completion was not sent to the DLQ for this order" ((QueueCount "OrderProcessed.dlq") -eq $opDlqBefore) "dlq=$(QueueCount 'OrderProcessed.dlq')"

    # (b) no StockReserved ever arrives: the requeue must be bounded. Inventory's
    # INSERT on its Inbox is revoked so this order's OrderPlaced is retried then
    # dead-lettered without producing any stock result -- the crafted completion
    # below is then the only thing that ever touches the order, not applicable,
    # forever, by construction. The never-warmed product also means reserve.lua
    # deducts nothing even before the failed write. The grant is restored in the
    # finally block.
    Sql "REVOKE INSERT ON inventory_service.processed_messages FROM inventory_service_user;" | Out-Null
    $o5 = Post-Order $pForged ("do-orphan-" + [guid]::NewGuid())
    Start-Sleep 3
    $logBeforeOrphan = @([regex]::Matches((Log "FlashSale.OrderService"), "arrived before its StockReserved")).Count
    Publish "OrderProcessed" (OrderProcessedPayload $o5)
    $bounded = Wait-Until { (QueueCount "OrderProcessed.dlq") -eq ($opDlqBefore + 1) } 90
    $orphanRetries = @([regex]::Matches((Log "FlashSale.OrderService"), "arrived before its StockReserved")).Count - $logBeforeOrphan
    Check "with no StockReserved the requeue is bounded: requeued, then dead-lettered" $bounded "dlq=$(QueueCount 'OrderProcessed.dlq') before=$opDlqBefore"
    Check "the orphan's completion was requeued three times (bounded ladder, not a straight DLQ, not forever)" (
        $orphanRetries -eq 3) "requeue log lines=$orphanRetries"
    Check "the orphaned order is left PendingStock and was never marked completed" (
        (State $o5) -eq "PendingStock" -and (OrdInbox $o5) -eq 0 -and (Ts $o5 "CompletedAt") -eq "-") "state=$(State $o5) inbox=$(OrdInbox $o5)"

    # (c) a late StockReserved after Completed stays a no-op.
    $stateBefore = State $o3; $decidedBefore = Ts $o3 "ConfirmedOrRejectedAt"
    $lateMsg = [guid]::NewGuid()
    Publish "StockReserved" (StockReservedPayload $o3 $lateMsg $p)
    $lateSeen = Wait-Until { (OrdInbox $lateMsg) -eq 1 } 30
    Start-Sleep 3
    Check "late StockReserved after Completed: no-op, decision and completion timestamps unchanged" (
        $lateSeen -and (State $o3) -eq "Completed" -and (Ts $o3 "ConfirmedOrRejectedAt") -eq $decidedBefore -and (Ts $o3 "CompletedAt") -ne "-") "state=$(State $o3) decided=$(Ts $o3 'ConfirmedOrRejectedAt')"
    Check "late StockReserved after Completed is not dead-lettered" ((QueueCount "StockReserved.dlq") -eq $srDlqBefore) "dlq=$(QueueCount 'StockReserved.dlq')"

    # ======================================================== end state
    # OrderPlaced.dlq and OrderProcessed.dlq are deliberately NOT asserted
    # empty: case 1 and case 3(b) suppress Inventory so those orders' OrderPlaced
    # messages dead-letter there (o1, o2 and the orphan o5), and case 3(b)
    # dead-letters the orphan's completion. Both were asserted at the point they
    # happened. Here only the run queues, the retry queues and the stock-result
    # DLQs (which must stay empty) are required to be drained.
    $all = $queues + @("StockReserved.dlq", "StockRejected.dlq") + $retryQueues
    $empty = Wait-Until { @($all | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0 } 60
    Check "every run queue, retry queue and stock-result DLQ is empty at the end" $empty (($all | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    Check "one unit deducted per applied order and no more: 30 - 2 = 28, Redis holds exactly those two orders" (
        (Stock $p) -eq "28" -and (Redis "SCARD", "processed:$p") -eq "2") "stock=$(Stock $p) reserved=$(Redis 'SCARD', "processed:$p")"
    Check "OrderPlaced.dlq holds exactly the three deliberately-dead-lettered OrderPlaced messages (o1, o2, o5)" (
        (QueueCount "OrderPlaced.dlq") -eq ($placedDlqBefore + 3)) "OrderPlaced.dlq=$(QueueCount 'OrderPlaced.dlq') before=$placedDlqBefore"
    Write-Host "    (OrderProcessed.dlq at the end: $(QueueCount 'OrderProcessed.dlq'), OrderPlaced.dlq: $(QueueCount 'OrderPlaced.dlq'))"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user; GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $proj }
    docker rm -f $mq $redis *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Concurrent duplicates, duplicate business events and out-of-order completion all leave one stock deduction and one applied result." -ForegroundColor Green
