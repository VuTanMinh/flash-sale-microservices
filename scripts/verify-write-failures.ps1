# ============================================================
# Week 15 write-failure and publish-crash cases (03A A-03, A-08; 03B B-08).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-write-failures.ps1 -Container verify-env-pg -DbPort 56432
#
# Same throwaway layout as verify-failures.ps1: Order Service, Inventory
# Service and the Process Worker on a throwaway RabbitMQ (5690/15690) and Redis
# (6399) against the given throwaway PostgreSQL container (create it with
# scripts\verify-environment.ps1 -Mode Fresh -Keep). Every fault is injected in
# that throwaway database or by stopping a process; no service code or setting
# changes.
#
#   A. C1 log insert fails after the stock UPDATE (TP-B05, A-03): INSERT on
#      order_service.baseline_orders revoked. A BEFORE UPDATE trigger on the
#      test product calls nextval() on a probe sequence; sequences are not
#      transactional, so the probe proves the stock UPDATE ran before the
#      failing INSERT. Each request fails with 5xx, the probe advances, the
#      stock and the log are unchanged (the whole transaction rolled back).
#      With the grant restored the same request deducts one unit and logs once.
#   B. State-save fault vs true duplicate in both result consumers (TP-W05,
#      A-08): UPDATE on order_service.orders revoked, so the state write itself
#      fails (not the Inbox insert, which TP-F01 covers). StockResult and
#      OrderProcessed: a transient fault is retried and applied once after the
#      grant returns; a fault that outlasts the ladder dead-letters the message
#      with no state change, and its replay applies once; a true duplicate
#      (same MessageId) is acknowledged as a no-op with nothing changed.
#   C. Crash after the publish confirm, before the Outbox row is marked sent
#      (TP-O03, B-08): after a real order completes, the publishing service is
#      killed and its Outbox row is set back to unsent, the state such a crash
#      leaves. On restart the row is published again with the same MessageId;
#      the receivers' Inboxes turn it into one business effect. Done for the
#      Order Outbox (OrderPlaced -> Inventory) and the Inventory Outbox
#      (StockReserved -> Order Service and the Process Worker).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432,
    [ValidateSet("A", "B", "C")][string[]]$Cases = @("A", "B", "C")
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-wf-mq"; $amqp = 5690; $mgmt = 15690; $redis = "verify-wf-redis"; $redisPort = 6399
$orderPort = 5132; $invPort = 5133; $workerPort = 5134
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__Enabled = "false" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "wf-$runId"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessingStarted.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name $(if ($detail) { "($detail)" })" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql, [string]$user = "flashsale") {
    $out = $sql | docker exec -i $Container psql -U $user -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql) { $v = Sql $sql; if ($v -notmatch '^-?\d+$') { return -1 }; return [int]$v }
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 20 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function QueueCount([string]$q) {
    $line = docker exec $mq rabbitmqctl -q list_queues name messages --no-table-headers 2>$null | Where-Object { ($_ -split "`t")[0] -eq $q }
    if ($line) { return [int](($line -split "`t")[1]) } else { return -1 }
}
function QueueExists([string]$q) { return ($null -ne (Mq Get "/queues/%2F/$q")) }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis([string[]]$cmd) { return (docker exec $redis redis-cli @cmd | Out-String).Trim() }
function Log([string]$project) {
    if (-not $logs[$project]) { return "" }
    $fs = New-Object IO.FileStream($logs[$project], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function LogCount([string]$project, [string]$needle) { return @((Log $project) -split "`r?`n" | Where-Object { $_.Contains($needle) }).Count }
function Running([string]$project) { return @(Get-CimInstance Win32_Process -Filter "Name='$project.exe'").Count -gt 0 }
function Stop-Svc([string]$project) {
    Get-CimInstance Win32_Process -Filter "Name='$project.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Wait-Until { -not (Running $project) } 20 | Out-Null
}
function Start-Svc([string]$project, [string]$tag) {
    $envs = @{} + $svcEnv[$project]
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-wf-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "wf-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function Post-C1([string]$product) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" -Body ('{"productId":"' + $product + '"}') `
            "http://localhost:$orderPort/api/c1/orders" -TimeoutSec 15
        return @{ Status = [int]$r.StatusCode; Body = $r.Content }
    } catch {
        $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ Status = $code; Body = "$($_.Exception.Message)" }
    }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function Col([string]$id, [string]$col) { return (Sql "SELECT `"$col`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function OrdInbox([string]$msg) { return (Int1 "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvInbox([string]$msg) { return (Int1 "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function HistRows([string]$id, [string]$to) { return (Int1 "SELECT count(*) FROM order_service.order_status_history WHERE `"OrderId`" = '$id' AND `"ToState`" = '$to';") }
function Publish([string]$eventType, [string]$payload) {
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $eventType; content_type = "application/json" }; routing_key = $eventType; payload = $payload; payload_encoding = "string" } | Out-Null
}
function DlqGet([string]$q) { return @(Mq Post "/queues/%2F/$q/get" @{ count = 1; ackmode = "ack_requeue_false"; encoding = "auto" } | ForEach-Object { $_ })[0] }
function Drained { return (@($allQueues | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0) }
function StockReservedPayload([string]$orderId, [string]$messageId, [string]$productId) {
    return "{`"OrderId`":`"$orderId`",`"ProductId`":`"$productId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-write-failures`"}"
}
function StartedPayload([string]$orderId, [string]$messageId) {
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-write-failures`",`"StartedAt`":`"$((Get-Date).ToUniversalTime().ToString('o'))`"}"
}
function ProcessedPayload([string]$orderId) {
    # The Worker's completion MessageId is the OrderId (docs/design-decisions.md).
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$orderId`",`"CorrelationId`":`"verify-write-failures`"}"
}
# An order in Processing without the Worker: StockReserved, then OrderProcessingStarted.
function To-Processing([string]$tag) {
    $id = Post-Order $p "wf-$tag-$([guid]::NewGuid())"
    Start-Sleep 1
    Publish "StockReserved" (StockReservedPayload $id ([guid]::NewGuid()) $p)
    Wait-Until { (State $id) -eq "Confirmed" } 20 | Out-Null
    Publish "OrderProcessingStarted" (StartedPayload $id ([guid]::NewGuid()))
    Wait-Until { (State $id) -eq "Processing" } 20 | Out-Null
    return $id
}

try {
    $dockerOk = $true; docker info *> $null; if ($LASTEXITCODE -ne 0) { $dockerOk = $false }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable; this verifier needs Docker" }
    if ((Int1 "SELECT 1;") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5132-5134" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-wf-definitions.json"; $conf = Join-Path $env:TEMP "verify-wf-rabbitmq.conf"
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
    Check "all three services up; every queue and DLQ declared" $ready
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 50 } -Force *> $null
    Check "warm-up: $p has 50 units" ((Redis "GET", "inventory:$p") -eq "50")

    # ============================================================ A. C1 rollback
    if ($Cases -contains "A") {
        Write-Host "== A. C1: log insert fails after the stock UPDATE (TP-B05, A-03)"
        $c1 = "wf-c1-$runId"
        Sql @"
INSERT INTO order_service.inventory (product_id, stock) VALUES ('$c1', 5);
CREATE SEQUENCE IF NOT EXISTS order_service.wf_update_probe;
GRANT USAGE ON SEQUENCE order_service.wf_update_probe TO order_service_user;
CREATE OR REPLACE FUNCTION order_service.wf_probe() RETURNS trigger LANGUAGE plpgsql AS `$`$ BEGIN PERFORM nextval('order_service.wf_update_probe'); RETURN NEW; END `$`$;
DROP TRIGGER IF EXISTS wf_probe ON order_service.inventory;
CREATE TRIGGER wf_probe BEFORE UPDATE ON order_service.inventory FOR EACH ROW WHEN (OLD.product_id = '$c1') EXECUTE FUNCTION order_service.wf_probe();
SELECT nextval('order_service.wf_update_probe');
"@ | Out-Null
        $probe0 = Int1 "SELECT last_value FROM order_service.wf_update_probe;"
        $stock = { Int1 "SELECT stock FROM order_service.inventory WHERE product_id = '$c1';" }
        $rows = { Int1 "SELECT count(*) FROM order_service.baseline_orders WHERE product_id = '$c1';" }
        Check "A setup: $c1 stock 5, no log rows" ((& $stock) -eq 5 -and (& $rows) -eq 0)

        Sql "REVOKE INSERT ON order_service.baseline_orders FROM order_service_user;" | Out-Null
        $codes = @(); foreach ($i in 1..3) { $codes += (Post-C1 $c1).Status }
        Sql "GRANT INSERT ON order_service.baseline_orders TO order_service_user;" | Out-Null
        $probe1 = Int1 "SELECT last_value FROM order_service.wf_update_probe;"
        Check "A.1 each request with the log insert refused fails (5xx), never 200" (@($codes | Where-Object { $_ -lt 500 }).Count -eq 0) "status=$($codes -join ',')"
        Check "A.1 the stock UPDATE ran before the failing insert in every request (probe +3)" (($probe1 - $probe0) -eq 3) "probe $probe0 -> $probe1"
        Check "A.1 the whole transaction rolled back: stock still 5" ((& $stock) -eq 5) "stock=$(& $stock)"
        Check "A.1 the whole transaction rolled back: no log row" ((& $rows) -eq 0) "rows=$(& $rows)"
        Check "A.1 the failure is the refused log insert (permission denied on baseline_orders)" ((Log "FlashSale.OrderService") -match "permission denied for table baseline_orders")

        $ok = Post-C1 $c1
        $res = $null; try { $res = $ok.Body | ConvertFrom-Json } catch { }
        $probe2 = Int1 "SELECT last_value FROM order_service.wf_update_probe;"
        Check "A.2 grant restored: the same request is Confirmed with 4 left" ($ok.Status -eq 200 -and $res.result -eq "Confirmed" -and $res.remainingStock -eq 4) "status=$($ok.Status) body=$($ok.Body)"
        Check "A.2 grant restored: stock 4, one log row (Confirmed), one more UPDATE" ((& $stock) -eq 4 -and (Int1 "SELECT count(*) FROM order_service.baseline_orders WHERE product_id = '$c1' AND result = 'Confirmed';") -eq 1 -and ($probe2 - $probe1) -eq 1) "stock=$(& $stock) rows=$(& $rows) probe=$probe2"
        Sql "DROP TRIGGER IF EXISTS wf_probe ON order_service.inventory; DROP FUNCTION IF EXISTS order_service.wf_probe(); DROP SEQUENCE IF EXISTS order_service.wf_update_probe;" | Out-Null
    }

    # ===================================== B. state-save fault vs true duplicate
    if ($Cases -contains "B") {
        Write-Host "== B. State-save fault vs true duplicate in both result consumers (TP-W05, A-08)"
        Wait-Until { Drained } 30 | Out-Null
        Stop-Svc "FlashSale.InventoryService"
        Stop-Svc "FlashSale.ProcessWorker"

        # B.1 StockResult, transient: UPDATE on orders refused for ~2 s
        $b1 = Post-Order $p "wf-b1-$([guid]::NewGuid())"; $mb1 = [guid]::NewGuid().ToString()
        Start-Sleep 1
        Sql "REVOKE UPDATE ON order_service.orders FROM order_service_user;" | Out-Null
        Publish "StockReserved" (StockReservedPayload $b1 $mb1 $p)
        Start-Sleep 2
        $during = State $b1; $inboxDuring = OrdInbox $mb1
        Sql "GRANT UPDATE ON order_service.orders TO order_service_user;" | Out-Null
        $applied = Wait-Until { (State $b1) -eq "Confirmed" } 30
        Check "B.1 StockResult: while the state write fails the order stays PendingStock with no Inbox row (not acked as done)" ($during -eq "PendingStock" -and $inboxDuring -eq 0) "state=$during inbox=$inboxDuring"
        Check "B.1 StockResult: the failure was retried (warning with the MessageId)" ((LogCount "FlashSale.OrderService" $mb1) -ge 2 -and (Log "FlashSale.OrderService") -match "permission denied for table orders")
        Check "B.1 StockResult: after the grant it is applied once (Confirmed, 1 Inbox row, 1 history row)" ($applied -and (OrdInbox $mb1) -eq 1 -and (HistRows $b1 "Confirmed") -eq 1) "state=$(State $b1)"
        Check "B.1 StockResult: nothing dead-lettered" ((QueueCount "StockReserved.dlq") -eq 0)

        # B.2 StockResult, true duplicate: the same MessageId again is acked as a no-op
        $decided = Col $b1 "ConfirmedOrRejectedAt"
        $dupBefore = LogCount "FlashSale.OrderService" "$mb1 for order $b1 already processed"
        Publish "StockReserved" (StockReservedPayload $b1 $mb1 $p)
        $acked = Wait-Until { (LogCount "FlashSale.OrderService" "$mb1 for order $b1 already processed") -gt $dupBefore } 20
        Check "B.2 StockResult duplicate: acknowledged as already processed" ($acked -and (QueueCount "StockReserved") -eq 0 -and (QueueCount "StockReserved.dlq") -eq 0)
        Check "B.2 StockResult duplicate: nothing changed (1 Inbox row, 1 history row, decision time unchanged)" ((OrdInbox $mb1) -eq 1 -and (HistRows $b1 "Confirmed") -eq 1 -and (Col $b1 "ConfirmedOrRejectedAt") -eq $decided)

        # B.3 OrderProcessed, transient
        $b3 = To-Processing "b3"
        Check "B.3 setup: order in Processing" ((State $b3) -eq "Processing") "state=$(State $b3)"
        Sql "REVOKE UPDATE ON order_service.orders FROM order_service_user;" | Out-Null
        Publish "OrderProcessed" (ProcessedPayload $b3)
        Start-Sleep 2
        $during = State $b3; $inboxDuring = OrdInbox $b3
        Sql "GRANT UPDATE ON order_service.orders TO order_service_user;" | Out-Null
        $done = Wait-Until { (State $b3) -eq "Completed" } 30
        Check "B.3 OrderProcessed: while the state write fails the order stays Processing with no Inbox row" ($during -eq "Processing" -and $inboxDuring -eq 0) "state=$during inbox=$inboxDuring"
        Check "B.3 OrderProcessed: the failure was retried" ((LogCount "FlashSale.OrderService" "Failed to process OrderProcessed $b3") -ge 1)
        Check "B.3 OrderProcessed: after the grant it is Completed once (1 Inbox row, 1 history row, CompletedAt set)" ($done -and (OrdInbox $b3) -eq 1 -and (HistRows $b3 "Completed") -eq 1 -and (Col $b3 "CompletedAt") -ne "") "state=$(State $b3)"
        Check "B.3 OrderProcessed: nothing dead-lettered" ((QueueCount "OrderProcessed.dlq") -eq 0)

        # B.4 OrderProcessed, the fault outlasts the retries: dead-lettered, not acked as done; replay applies once
        $b4 = To-Processing "b4"
        Sql "REVOKE UPDATE ON order_service.orders FROM order_service_user;" | Out-Null
        Publish "OrderProcessed" (ProcessedPayload $b4)
        $dead = Wait-Until { (QueueCount "OrderProcessed.dlq") -eq 1 } 60
        $retries = @((Log "FlashSale.OrderService") -split "`r?`n" | Where-Object { $_.Contains("Failed to process OrderProcessed $b4") -and $_.Contains("retrying in") }).Count
        $final = LogCount "FlashSale.OrderService" "Failed to process OrderProcessed $b4 for order $b4 after 4 attempts; routing to DLQ"
        Check "B.4 OrderProcessed exhausted: 3 retries, then after 4 attempts the message is in OrderProcessed.dlq" ($dead -and $retries -eq 3 -and $final -eq 1) "dlq=$(QueueCount 'OrderProcessed.dlq') retries=$retries final=$final"
        Check "B.4 OrderProcessed exhausted: no state change and no Inbox row" ((State $b4) -eq "Processing" -and (OrdInbox $b4) -eq 0 -and (HistRows $b4 "Completed") -eq 0)
        Sql "GRANT UPDATE ON order_service.orders TO order_service_user;" | Out-Null
        $msg = DlqGet "OrderProcessed.dlq"
        Publish "OrderProcessed" $msg.payload
        $done = Wait-Until { (State $b4) -eq "Completed" } 30
        Check "B.4 OrderProcessed replay after the fix: Completed once" ($done -and (OrdInbox $b4) -eq 1 -and (HistRows $b4 "Completed") -eq 1)

        # B.5 OrderProcessed, true duplicate
        $completedAt = Col $b3 "CompletedAt"
        $dupBefore = LogCount "FlashSale.OrderService" "OrderProcessed $b3 for order $b3 already processed"
        Publish "OrderProcessed" (ProcessedPayload $b3)
        $acked = Wait-Until { (LogCount "FlashSale.OrderService" "OrderProcessed $b3 for order $b3 already processed") -gt $dupBefore } 20
        Check "B.5 OrderProcessed duplicate: acknowledged as already processed" ($acked -and (QueueCount "OrderProcessed") -eq 0 -and (QueueCount "OrderProcessed.dlq") -eq 0)
        Check "B.5 OrderProcessed duplicate: nothing changed (1 Inbox row, 1 history row, CompletedAt unchanged)" ((OrdInbox $b3) -eq 1 -and (HistRows $b3 "Completed") -eq 1 -and (Col $b3 "CompletedAt") -eq $completedAt)

        Start-Svc "FlashSale.InventoryService" "b-restart"
        Start-Svc "FlashSale.ProcessWorker" "b-restart"
    }

    # ========================= C. crash after publish confirm, before mark sent
    if ($Cases -contains "C") {
        Write-Host "== C. Crash after the publish confirm, before the Outbox row is marked sent (TP-O03, B-08)"
        Wait-Until { Drained } 30 | Out-Null

        # C.1 Order Outbox: OrderPlaced to Inventory
        $c1o = Post-Order $p "wf-c1o-$([guid]::NewGuid())"
        $completed = Wait-Until { (State $c1o) -eq "Completed" } 60
        Check "C.1 setup: a real order completes end to end" $completed "state=$(State $c1o)"
        $row = Sql "SELECT `"Id`" FROM order_service.outbox_events WHERE `"OrderId`" = '$c1o';"
        $placedMsg = Sql "SELECT `"Payload`"->>'MessageId' FROM order_service.outbox_events WHERE `"OrderId`" = '$c1o';"
        $stock0 = Redis "GET", "inventory:$p"; $set0 = Redis "SCARD", "processed:$p"
        $sentAt0 = Sql "SELECT `"PublishedAt`" FROM order_service.outbox_events WHERE `"Id`" = '$row';"
        $recv0 = LogCount "FlashSale.InventoryService" "Received OrderPlaced $placedMsg"
        Stop-Svc "FlashSale.OrderService"
        Sql "UPDATE order_service.outbox_events SET `"Published`" = false, `"PublishedAt`" = NULL WHERE `"Id`" = '$row';" | Out-Null
        Check "C.1 crash state: Order Service killed, its OrderPlaced row back to unsent" ((-not (Running "FlashSale.OrderService")) -and (Sql "SELECT `"Published`" FROM order_service.outbox_events WHERE `"Id`" = '$row';") -eq "f")
        Start-Svc "FlashSale.OrderService" "c1-restart"
        $resent = Wait-Until { (Sql "SELECT `"Published`" FROM order_service.outbox_events WHERE `"Id`" = '$row';") -eq "t" } 30
        $redelivered = Wait-Until { (LogCount "FlashSale.InventoryService" "OrderPlaced $placedMsg for order $c1o already processed") -ge 1 } 30
        Start-Sleep 2
        Check "C.1 restart: the row is published again with the same MessageId" ($resent -and (Sql "SELECT `"Payload`"->>'MessageId' FROM order_service.outbox_events WHERE `"Id`" = '$row';") -eq $placedMsg -and (Sql "SELECT `"PublishedAt`" FROM order_service.outbox_events WHERE `"Id`" = '$row';") -ne $sentAt0)
        Check "C.1 Inventory received the duplicate and acked it as already processed" ($redelivered -and (LogCount "FlashSale.InventoryService" "Received OrderPlaced $placedMsg") -eq ($recv0 + 1))
        Check "C.1 one business effect: 1 Inventory Inbox row, stock and reserved set unchanged, 1 result row" ((InvInbox $placedMsg) -eq 1 -and (Redis "GET", "inventory:$p") -eq $stock0 -and (Redis "SCARD", "processed:$p") -eq $set0 -and (Int1 "SELECT count(*) FROM inventory_service.outbox_events WHERE `"OrderId`" = '$c1o';") -eq 1) "stock $stock0 -> $(Redis "GET", "inventory:$p")"
        Check "C.1 the order is untouched (Completed, one history row per state)" ((State $c1o) -eq "Completed" -and (HistRows $c1o "Confirmed") -eq 1 -and (HistRows $c1o "Completed") -eq 1)

        # C.2 Inventory Outbox: StockReserved to Order Service and the Process Worker
        $c2o = Post-Order $p "wf-c2o-$([guid]::NewGuid())"
        $completed = Wait-Until { (State $c2o) -eq "Completed" } 60
        Check "C.2 setup: a real order completes end to end" $completed "state=$(State $c2o)"
        $irow = Sql "SELECT `"Id`" FROM inventory_service.outbox_events WHERE `"OrderId`" = '$c2o';"
        $resMsg = Sql "SELECT `"Payload`"->>'MessageId' FROM inventory_service.outbox_events WHERE `"Id`" = '$irow';"
        $stock0 = Redis "GET", "inventory:$p"; $set0 = Redis "SCARD", "processed:$p"
        $decided = Col $c2o "ConfirmedOrRejectedAt"; $completedAt = Col $c2o "CompletedAt"
        $worker0 = LogCount "FlashSale.ProcessWorker" "Order $c2o processed in"
        Stop-Svc "FlashSale.InventoryService"
        Sql "UPDATE inventory_service.outbox_events SET `"Published`" = false, `"PublishedAt`" = NULL WHERE `"Id`" = '$irow';" | Out-Null
        Check "C.2 crash state: Inventory killed, its StockReserved row back to unsent" ((-not (Running "FlashSale.InventoryService")) -and (Sql "SELECT `"Published`" FROM inventory_service.outbox_events WHERE `"Id`" = '$irow';") -eq "f")
        Start-Svc "FlashSale.InventoryService" "c2-restart"
        $resent = Wait-Until { (Sql "SELECT `"Published`" FROM inventory_service.outbox_events WHERE `"Id`" = '$irow';") -eq "t" } 30
        $orderDup = Wait-Until { (LogCount "FlashSale.OrderService" "StockReserved $resMsg for order $c2o already processed") -ge 1 } 30
        $workerDup = Wait-Until { (LogCount "FlashSale.OrderService" "OrderProcessed $c2o for order $c2o already processed") -ge 1 } 30
        Start-Sleep 2
        Check "C.2 restart: the row is published again with the same MessageId" ($resent -and (Sql "SELECT `"Payload`"->>'MessageId' FROM inventory_service.outbox_events WHERE `"Id`" = '$irow';") -eq $resMsg)
        Check "C.2 Order Service acked the duplicate StockReserved as already processed" $orderDup
        Check "C.2 the Worker repeated its deterministic work and its OrderProcessed (MessageId = OrderId) was acked as already processed" ($workerDup -and (LogCount "FlashSale.ProcessWorker" "Order $c2o processed in") -eq ($worker0 + 1))
        Check "C.2 one business effect: 1 Inbox row each, Confirmed and Completed once, times unchanged" ((OrdInbox $resMsg) -eq 1 -and (OrdInbox $c2o) -eq 1 -and (HistRows $c2o "Confirmed") -eq 1 -and (HistRows $c2o "Completed") -eq 1 -and (Col $c2o "ConfirmedOrRejectedAt") -eq $decided -and (Col $c2o "CompletedAt") -eq $completedAt)
        Check "C.2 no second deduction: stock and reserved set unchanged" ((Redis "GET", "inventory:$p") -eq $stock0 -and (Redis "SCARD", "processed:$p") -eq $set0)
        $dlqs = @($allDlqs | Where-Object { (QueueCount $_) -ne 0 })
        Check "C every DLQ empty; every main queue drained" ($dlqs.Count -eq 0 -and (Wait-Until { Drained } 20)) "non-empty: $($dlqs -join ',')"
    }
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON order_service.baseline_orders TO order_service_user; GRANT UPDATE ON order_service.orders TO order_service_user; DROP TRIGGER IF EXISTS wf_probe ON order_service.inventory; DROP FUNCTION IF EXISTS order_service.wf_probe(); DROP SEQUENCE IF EXISTS order_service.wf_update_probe;" | Out-Null
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $proj }
    docker rm -f $mq $redis *> $null
}
Write-Host ""
Write-Host "Exit code: $(if ($failures -gt 0) { 1 } else { 0 })"
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "A failed C1 log insert rolls back its stock UPDATE; a failed state write is retried or dead-lettered, never acked as done, while a true duplicate is acked as a no-op; a re-published Outbox row after a crash before the mark has one business effect." -ForegroundColor Green
