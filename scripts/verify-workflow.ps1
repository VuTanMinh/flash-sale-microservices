# ============================================================
# Week 8 TP-W04: the main workflow (docs/workflow.md) and its sequence
# diagrams (docs/sequence-diagrams.md) match the implementation.
#
#   Static only (no services):
#     powershell -ExecutionPolicy Bypass -File .\scripts\verify-workflow.ps1
#   Static + live trace of real orders through all three services:
#     powershell -ExecutionPolicy Bypass -File .\scripts\verify-workflow.ps1 -Container verify-env-pg -DbPort 55432
#
# Static: every claim in the diagrams is compared with the code and the
# appsettings files, and the diagram blocks must equal report/figures/*.mmd.
# Live: one reserved order (with a client replay), one sold-out order and one
# order for a product that was never warmed up are traced through Order
# Service, Inventory Service and the Process Worker on a throwaway RabbitMQ
# and Redis. Their database rows, timestamps, Redis keys and logs must follow
# the diagram's steps in order.
# ============================================================
param(
    [string]$Container = "",
    [int]$DbPort = 55432,
    [string]$DiagramDoc = ""
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $DiagramDoc) { $DiagramDoc = Join-Path $repoRoot "docs\sequence-diagrams.md" }
$failures = 0

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repoRoot $rel)) }
# Source code with full-line comments removed, so a class or method named in a
# comment cannot satisfy (or break) an ordering check.
function Code([string]$rel) { return ((Src $rel) -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^//' }) -join "`n" }
function Norm([string]$s) { return (($s -replace "`r`n", "`n").Trim()) }
function Before([string]$text, [string]$first, [string]$second) {
    $i = $text.IndexOf($first); $j = $text.IndexOf($second)
    return ($i -ge 0 -and $j -ge 0 -and $i -lt $j)
}

# ================================================================ static
Write-Host "== Static: diagrams against code and configuration ($DiagramDoc)"
$doc = [IO.File]::ReadAllText($DiagramDoc)
$blocks = @([regex]::Matches($doc, '(?s)```mermaid\r?\n(.*?)```') | ForEach-Object { Norm $_.Groups[1].Value })
$hp = ""; $rj = ""; $pl = ""
foreach ($b in $blocks) {
    if ($b.Contains("PLANNED (Week 11)")) { $pl = $b }
    elseif ($b.Contains("Process Worker")) { $hp = $b }
    else { $rj = $b }
}
Check "doc has a happy-path, a rejection and a planned diagram" ($hp -and $rj -and $pl)
foreach ($pair in @(@("seq-happy-path", $hp), @("seq-rejection", $rj), @("seq-planned-processing", $pl))) {
    $fig = Norm (Src "report\figures\$($pair[0]).mmd")
    Check "report/figures/$($pair[0]).mmd is identical to the diagram in the doc" ($fig -eq $pair[1])
}
$both = $hp + "`n" + $rj

$ctrl = Code "src\FlashSale.OrderService\Controllers\OrdersController.cs"
$opw = Code "src\FlashSale.OrderService\Messaging\OutboxPublisherWorker.cs"
$ipw = Code "src\FlashSale.InventoryService\Messaging\OutboxPublisherWorker.cs"
$publishers = @{
    "Order" = Code "src\FlashSale.OrderService\Messaging\RabbitMqOutboxPublisher.cs"
    "Inventory" = Code "src\FlashSale.InventoryService\Messaging\RabbitMqOutboxPublisher.cs"
    "Process Worker" = Code "src\FlashSale.ProcessWorker\Messaging\OrderProcessedPublisher.cs"
}
$proc = Code "src\FlashSale.InventoryService\Messaging\OrderPlacedProcessor.cs"
$res = Code "src\FlashSale.InventoryService\Inventory\InventoryReservationService.cs"
$srp = Code "src\FlashSale.OrderService\Messaging\StockResultProcessor.cs"
$opc = Code "src\FlashSale.OrderService\Messaging\OrderProcessedConsumer.cs"
$wcon = Code "src\FlashSale.ProcessWorker\Messaging\StockReservedConsumer.cs"
$states = Code "src\FlashSale.OrderService\Entities\OrderState.cs"
$nginx = Src "infra\nginx.conf"
$orderCfg = (Src "src\FlashSale.OrderService\appsettings.json") | ConvertFrom-Json
$invCfg = (Src "src\FlashSale.InventoryService\appsettings.json") | ConvertFrom-Json
$wrkCfg = (Src "src\FlashSale.ProcessWorker\appsettings.json") | ConvertFrom-Json

# Steps 1-4: intake
Check "steps 1-4: POST answers 201 Created (diagram and controller)" ($hp.Contains("201 Created (state PendingStock)") -and $ctrl -match 'StatusCode\(201')
Check "steps 2-3: key lookup, then order + OrderPlaced Outbox row in one SaveChangesAsync" (
    $hp.Contains("look up the Idempotency-Key") -and $hp.Contains("one transaction: INSERT order (PendingStock) + Outbox row OrderPlaced") -and
    (Before $ctrl "o.IdempotencyKey == idempotencyKey" "Orders.Add(order)") -and (Before $ctrl "OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order))" "SaveChangesAsync") -and
    ([regex]::Matches($ctrl, 'SaveChangesAsync\(').Count -eq 1))

# Steps 5-9 and 16-20: both Outbox publishers
foreach ($w in @(@("Order", $opw), @("Inventory", $ipw))) {
    $poll = [regex]::Match($w[1], 'PollInterval = TimeSpan\.FromSeconds\((\d+)\)').Groups[1].Value
    Check "$($w[0]) Outbox publisher: polls every ${poll}s, up to 50 rows, oldest first (as drawn)" (
        $poll -eq "2" -and $w[1].Contains(".OrderBy(e => e.CreatedAt)") -and $w[1].Contains(".Take(50)") -and
        ([regex]::Matches($hp, 'loop every 2s').Count -eq 2) -and $hp.Contains("SELECT up to 50 unpublished rows, oldest first"))
    Check "$($w[0]) Outbox publisher marks a row published only after a confirmed publish" (
        $w[1] -match '(?s)var published = await TryPublishWithRetryAsync\(.*?if \(published\)\s*\{\s*outboxEvent\.MarkPublished\(\)' -and
        $w[1] -match 'await publisher\.PublishAsync\([^;]*\);\s*return true;')
}
foreach ($name in $publishers.Keys) {
    $p = $publishers[$name]
    Check "$name publisher: required-queue check, mandatory publish, tracked confirms" (
        $p.Contains("QueueDeclarePassiveAsync") -and $p.Contains("mandatory: true") -and $p.Contains("publisherConfirmationTrackingEnabled: true") -and
        (Before $p "QueueDeclarePassiveAsync" "BasicPublishAsync"))
}
Check "every publish arrow is drawn as mandatory with a confirm" ([regex]::Matches($both, 'publish \w+ \([^)]*mandatory[^)]*confirm').Count -eq 4)

# Required subscriber queues per event, from each service's appsettings.json
$required = @{}
foreach ($cfg in @($orderCfg, $invCfg, $wrkCfg)) {
    foreach ($prop in $cfg.RabbitMQ.EventBus.RequiredSubscriberQueues.PSObject.Properties) { $required[$prop.Name] = @($prop.Value) }
}
foreach ($evt in "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed") {
    $qs = @($required[$evt])
    $text = if ($qs.Count -eq 1) { "check required queue $($qs[0])" } else { "check required queues " + ($qs -join " and ") }
    Check "$evt is drawn with exactly its configured required queues ($($qs -join ', '))" ($qs.Count -ge 1 -and $both.Contains($text)) $text
}

# Steps 10-15: reservation
Check "steps 11-12: Inventory checks its Inbox before running reserve.lua (code and diagram)" (
    (Before $proc "ProcessedMessages.AnyAsync" "ReserveAsync") -and (Before $hp "Inbox: MessageId already processed?" "EVAL reserve.lua"))
Check "step 12: reserve.lua gets the inventory, processed and sale:open keys" (
    $res.Contains('$"inventory:{productId}"') -and $res.Contains('$"processed:{productId}"') -and $res.Contains('$"sale:open:{productId}"') -and
    $both.Contains("EVAL reserve.lua (inventory, processed and sale:open keys)"))
Check "outcome mapping: RESERVED/DUPLICATE -> StockReserved, REJECTED/NOT_OPEN -> StockRejected" (
    $proc -match 'ReservationResult\.Reserved => "StockReserved"' -and $proc -match 'ReservationResult\.Duplicate => "StockReserved"' -and
    $proc -match 'ReservationResult\.Rejected => "StockRejected"' -and $proc -match 'ReservationResult\.NotOpen => "StockRejected"' -and
    $hp.Contains("RESERVED (") -and $rj.Contains("REJECTED (nothing deducted)") -and $rj.Contains("NOT_OPEN (nothing deducted)"))
Check "step 14: Outbox row (only if none for the OrderId) and Inbox row in one SaveChangesAsync" (
    $proc.Contains("OutboxEvents.AnyAsync(e => e.OrderId == orderPlaced.OrderId)") -and (Before $proc "OutboxEvents.Add(" "SaveChangesAsync") -and
    (Before $proc "ProcessedMessages.Add(" "SaveChangesAsync") -and ([regex]::Matches($proc, 'SaveChangesAsync\(').Count -eq 1) -and
    $hp.Contains("one transaction: Outbox row StockReserved (if none for this OrderId) + Inbox row") -and
    $rj.Contains("one transaction: Outbox row StockRejected (if none for this OrderId) + Inbox row"))

# Ack only after the processing call, in all four consumers
foreach ($c in @(
        @("Inventory OrderPlaced", "src\FlashSale.InventoryService\Messaging\OrderPlacedConsumer.cs"),
        @("Order StockResult", "src\FlashSale.OrderService\Messaging\StockResultConsumer.cs"),
        @("Order OrderProcessed", "src\FlashSale.OrderService\Messaging\OrderProcessedConsumer.cs"),
        @("Process Worker StockReserved", "src\FlashSale.ProcessWorker\Messaging\StockReservedConsumer.cs"))) {
    $s = Code $c[1]
    Check "$($c[0]) consumer acks only after processing (autoAck off)" ((Before $s "await ProcessWithRetryAsync(" "BasicAckAsync") -and $s.Contains("autoAck: false"))
}

# Steps 21-23 and 28-30: applying results in Order Service
Check "steps 22/29: Inbox check, transition and Inbox row in one save (StockResultProcessor)" (
    (Before $srp "ProcessedMessages.AnyAsync" "order.TransitionTo(targetState)") -and (Before ($srp.Substring([Math]::Max(0, $srp.IndexOf("order.TransitionTo(targetState);")))) "ProcessedMessages.Add(" "await saveChangesAsync()") -and
    $hp.Contains("one transaction: Inbox check, PendingStock to Confirmed, Inbox row") -and $rj.Contains("one transaction: Inbox check, PendingStock to Rejected, Inbox row") -and
    $hp.Contains("one transaction: Inbox check, Confirmed to Completed, Inbox row"))
Check "step 29: OrderProcessed reuses StockResultProcessor with target Completed" ($opc.Contains('StockResultProcessor.ProcessAsync(') -and $opc.Contains('"OrderProcessed", OrderState.Completed'))

# Steps 21-27: the fork
$osQueue = $orderCfg.RabbitMQ.EventBus.StockReservedQueueName; $pwQueue = $wrkCfg.RabbitMQ.EventBus.StockReservedQueueName
Check "the fork is drawn as par over the two configured queues ($osQueue, $pwQueue)" ($hp.Contains("par queue $osQueue") -and $hp.Contains("and queue $pwQueue"))
$delay = $wrkCfg.Processing.DelayMilliseconds
Check "step 25: Process Worker delay is the configured ${delay} ms" ($hp.Contains("fixed processing delay ($delay ms)") -and $wcon.Contains("Task.Delay(_processingOptions.DelayMilliseconds"))
Check "step 26: OrderProcessed MessageId = OrderId (code and diagram)" ($wcon.Contains("MessageId = stockReserved.OrderId") -and $hp.Contains("MessageId = OrderId"))
Check "Process Worker binds only StockReserved, and the rejection path does not draw it" (
    $wcon.Contains('routingKey: "StockReserved"') -and -not $wcon.Contains('"StockRejected"') -and -not $rj.Contains("Process Worker"))

# Steps 31-32, Nginx and the planned hop
Check "steps 31-32: polling returns the final state" ($hp.Contains("200 OK (state Completed)") -and $rj.Contains("200 OK (state Rejected)"))
$nginxForwards = $nginx -match 'proxy_pass'
Check "Nginx is drawn only if infra/nginx.conf forwards requests (forwards: $nginxForwards)" (($both -match 'Nginx') -eq $nginxForwards)
Check "Processing is drawn only as PLANNED while OrderState has no Processing" ((-not ($states -match '\bProcessing\b')) -and $pl.Contains("PLANNED (Week 11), not in code yet") -and -not ($both -match 'state=Processing|to Processing'))

# ================================================================ live
if ($Container) {
    Write-Host ""
    Write-Host "== Live: real orders traced through all three services"
    $mq = "verify-wf-mq"; $amqp = 5687; $mgmt = 15687; $redis = "verify-wf-redis"; $redisPort = 6396
    $orderPort = 5121; $invPort = 5122; $workerPort = 5123
    $ex = "flashsale.order.exchange"
    $started = @()
    $auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
    function Sql([string]$sql) { $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -; return (@($out | Where-Object { $_ -ne "" }) -join "`n") }
    function Mq([string]$path) { try { return Invoke-RestMethod -Method Get -Headers $auth -Uri "http://localhost:$mgmt/api$path" -TimeoutSec 10 } catch { return $null } }
    function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
    function Redis([string[]]$cmd) { return (docker exec $redis redis-cli @cmd | Out-String).Trim() }
    # The running service holds its log open, so read it with shared access.
    function Log([string]$project) {
        $fs = New-Object IO.FileStream((Join-Path $env:TEMP "verify-wf-$project.log"), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    }
    function Start-Svc([string]$project, [hashtable]$envs) {
        foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
        $log = Join-Path $env:TEMP "verify-wf-$project.log"
        $p = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
        foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
        $script:started += $p
    }
    function Post-Order([string]$product, [string]$key) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" -Headers @{ "Idempotency-Key" = $key } `
                -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
            return @{ Code = [int]$r.StatusCode; Body = ($r.Content | ConvertFrom-Json) }
        } catch { return @{ Code = -1; Body = $null } }
    }
    function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
    # Every path timestamp of one order as epoch microseconds, keyed by name.
    function Trace([string]$id) {
        $us = { param($col) "coalesce((extract(epoch from $col) * 1000000)::bigint, -1)" }
        $row = Sql @"
WITH o AS (SELECT * FROM order_service.orders WHERE "Id" = '$id'),
     oo AS (SELECT * FROM order_service.outbox_events WHERE "Payload"->>'OrderId' = '$id'),
     io AS (SELECT * FROM inventory_service.outbox_events WHERE "OrderId" = '$id')
SELECT concat_ws('|',
  (SELECT $(& $us '"RequestAcceptedAt"') FROM o),
  (SELECT $(& $us '"ConfirmedOrRejectedAt"') FROM o),
  (SELECT $(& $us '"CompletedAt"') FROM o),
  (SELECT count(*) FROM oo),
  (SELECT "EventType" || ':' || "Published" FROM oo LIMIT 1),
  (SELECT $(& $us '"CreatedAt"') FROM oo LIMIT 1),
  (SELECT "Payload"->>'MessageId' FROM oo LIMIT 1),
  (SELECT count(*) FROM inventory_service.processed_messages WHERE "MessageId"::text = (SELECT "Payload"->>'MessageId' FROM oo LIMIT 1)),
  (SELECT coalesce(max($(& $us '"ProcessedAt"')), -1) FROM inventory_service.processed_messages WHERE "MessageId"::text = (SELECT "Payload"->>'MessageId' FROM oo LIMIT 1)),
  (SELECT count(*) FROM io),
  (SELECT "EventType" || ':' || "Published" FROM io LIMIT 1),
  (SELECT $(& $us '"CreatedAt"') FROM io LIMIT 1),
  (SELECT "Payload"->>'MessageId' FROM io LIMIT 1),
  (SELECT count(*) FROM order_service.processed_messages WHERE "MessageId"::text = (SELECT "Payload"->>'MessageId' FROM io LIMIT 1)),
  (SELECT coalesce(max($(& $us '"ProcessedAt"')), -1) FROM order_service.processed_messages WHERE "MessageId"::text = (SELECT "Payload"->>'MessageId' FROM io LIMIT 1)),
  (SELECT count(*) FROM order_service.processed_messages WHERE "MessageId" = '$id'),
  (SELECT coalesce(max($(& $us '"ProcessedAt"')), -1) FROM order_service.processed_messages WHERE "MessageId" = '$id'));
"@
        $f = @($row -split '\|')
        $names = "accepted", "decided", "completed", "oOutboxRows", "oOutbox", "oOutboxCreated", "orderPlacedMsg", "invInboxRows", "invInboxAt",
            "iOutboxRows", "iOutbox", "iOutboxCreated", "resultMsg", "oResultInboxRows", "oResultInboxAt", "oProcessedInboxRows", "oProcessedInboxAt"
        $t = @{}
        for ($i = 0; $i -lt $names.Count; $i++) { $t[$names[$i]] = if ($i -lt $f.Count) { $f[$i] } else { "" } }
        foreach ($n in "accepted", "decided", "completed", "oOutboxCreated", "invInboxAt", "iOutboxCreated", "oResultInboxAt", "oProcessedInboxAt", "oOutboxRows", "invInboxRows", "iOutboxRows", "oResultInboxRows", "oProcessedInboxRows") {
            $v = 0L; if ([long]::TryParse("$($t[$n])", [ref]$v)) { $t[$n] = $v } else { $t[$n] = -1L }
        }
        return $t
    }
    function Show($t) { return (($t.Keys | Sort-Object | ForEach-Object { "$_=$($t[$_])" }) -join " ") }

    $runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
    $p = "wf-$runId"; $closed = "wf-closed-$runId"
    try {
        docker rm -f $mq $redis *> $null
        docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
        $defs = Join-Path $env:TEMP "verify-wf-definitions.json"; $conf = Join-Path $env:TEMP "verify-wf-rabbitmq.conf"
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
        if (-not (Wait-Until { $null -ne (Mq "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

        $pg = "Host=localhost;Port=$DbPort;Database=flashsale"
        Start-Svc "FlashSale.OrderService" @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
        Start-Svc "FlashSale.InventoryService" @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
        Start-Svc "FlashSale.ProcessWorker" @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
        $queues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed", "ProcessWorker.StockReserved"
        $ready = Wait-Until { @($queues | Where-Object { $null -eq (Mq "/queues/%2F/$_") }).Count -eq 0 } 120
        Check "all three services up; all five consumer queues declared" $ready
        if (-not $ready) { throw "services did not come up; see $env:TEMP\verify-wf-*.log" }

        & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 1 } -Force *> $null
        Check "warm-up: $p has 1 unit and is open; $closed was never warmed up" ((Redis "GET", "inventory:$p") -eq "1" -and (Redis "EXISTS", "sale:open:$p") -eq "1" -and (Redis "EXISTS", "sale:open:$closed") -eq "0")

        # ---------- A: reserved, processed, completed ----------
        $keyA = "wf-" + [guid]::NewGuid()
        $a = Post-Order $p $keyA
        $idA = "$($a.Body.id)"
        Check "A steps 1-4: 201 with state PendingStock" ($a.Code -eq 201 -and $a.Body.state -eq "PendingStock") "$($a.Code) $($a.Body.state)"
        $replay = Post-Order $p $keyA
        Check "A: client replay with the same key answers 200 with the same order" ($replay.Code -eq 200 -and "$($replay.Body.id)" -eq $idA)
        $done = Wait-Until { (State $idA) -eq "Completed" } 60
        Check "A: reached Completed" $done (State $idA)
        $t = Trace $idA
        Write-Host "      trace A: $(Show $t)"
        Check "A step 3: one OrderPlaced Outbox row, written with the order (CreatedAt >= RequestAcceptedAt)" ($t.oOutboxRows -eq 1 -and $t.oOutboxCreated -ge $t.accepted -and $t.accepted -gt 0)
        Check "A step 9: the OrderPlaced row is marked published" ($t.oOutbox -eq "OrderPlaced:true") $t.oOutbox
        Check "A step 14: Inventory Inbox row for that MessageId, after the Outbox row was committed" ($t.invInboxRows -eq 1 -and $t.invInboxAt -gt $t.oOutboxCreated)
        Check "A step 14: one StockReserved Outbox row, in the same step as the Inbox row" ($t.iOutboxRows -eq 1 -and $t.iOutbox -like "StockReserved:*" -and $t.iOutboxCreated -gt $t.oOutboxCreated -and $t.iOutboxCreated -le $t.invInboxAt)
        Check "A step 20: the StockReserved row is marked published" ($t.iOutbox -eq "StockReserved:true") $t.iOutbox
        Check "A step 22: Confirmed after the result existed, with one Inbox row for the result's MessageId" ($t.decided -gt $t.iOutboxCreated -and $t.oResultInboxRows -eq 1 -and $t.oResultInboxAt -ge $t.decided)
        Check "A step 29: Completed after Confirmed, with one Inbox row whose MessageId is the OrderId" ($t.completed -gt $t.decided -and $t.oProcessedInboxRows -eq 1 -and $t.oProcessedInboxAt -ge $t.completed)
        Check "A step 13: Redis deducted one unit and recorded the order" ((Redis "GET", "inventory:$p") -eq "0" -and (Redis "SISMEMBER", "processed:$p", $idA) -eq "1")
        $invLog = Log "FlashSale.InventoryService"; $wrkLog = Log "FlashSale.ProcessWorker"; $ordLog = Log "FlashSale.OrderService"
        Check "A steps 10-13: Inventory logged the reservation as Reserved" ($invLog.Contains("OrderPlaced $idA for product $p -> Reserved"))
        Check "A steps 24-26: Process Worker received StockReserved and published OrderProcessed" (Before $wrkLog "Received StockReserved for order $idA" "Order $idA processed in")
        Check "A: Order Service logged Confirmed before Completed" (Before $ordLog "Order $idA -> Confirmed" "Order $idA -> Completed")
        Check "A: still exactly one order for the replayed key" ((Sql "SELECT count(*) FROM order_service.orders WHERE `"IdempotencyKey`" = '$keyA';") -eq "1")

        # ---------- B: sold out ----------
        $b = Post-Order $p ("wf-" + [guid]::NewGuid())
        $idB = "$($b.Body.id)"
        Check "B: 201 with state PendingStock" ($b.Code -eq 201 -and $b.Body.state -eq "PendingStock")
        $done = Wait-Until { (State $idB) -eq "Rejected" } 60
        Check "B: sold out -> Rejected" $done (State $idB)
        $t = Trace $idB
        Write-Host "      trace B: $(Show $t)"
        Check "B: OrderPlaced published, one StockRejected Outbox row published, after the Inbox check" ($t.oOutbox -eq "OrderPlaced:true" -and $t.iOutboxRows -eq 1 -and $t.iOutbox -eq "StockRejected:true" -and $t.invInboxRows -eq 1 -and $t.iOutboxCreated -le $t.invInboxAt)
        Check "B: Rejected after the result existed, one result Inbox row, never completed" ($t.decided -gt $t.iOutboxCreated -and $t.oResultInboxRows -eq 1 -and $t.completed -eq -1 -and $t.oProcessedInboxRows -eq 0)
        Check "B: Lua answered Rejected and deducted nothing" ((Log "FlashSale.InventoryService").Contains("OrderPlaced $idB for product $p -> Rejected") -and (Redis "GET", "inventory:$p") -eq "0" -and (Redis "SISMEMBER", "processed:$p", $idB) -eq "0")
        Check "B: the Process Worker never saw it" (-not (Log "FlashSale.ProcessWorker").Contains($idB))

        # ---------- C: sale not open ----------
        $c = Post-Order $closed ("wf-" + [guid]::NewGuid())
        $idC = "$($c.Body.id)"
        $done = Wait-Until { (State $idC) -eq "Rejected" } 60
        Check "C: product never warmed up -> Rejected" ($c.Code -eq 201 -and $done) (State $idC)
        $t = Trace $idC
        Write-Host "      trace C: $(Show $t)"
        Check "C: Lua answered NotOpen; one StockRejected row; nothing created in Redis" (
            (Log "FlashSale.InventoryService").Contains("OrderPlaced $idC for product $closed -> NotOpen") -and $t.iOutbox -eq "StockRejected:true" -and
            (Redis "EXISTS", "inventory:$closed") -eq "0" -and (Redis "EXISTS", "processed:$closed") -eq "0")
        Check "C: never completed and never reached the Process Worker" ($t.completed -eq -1 -and -not (Log "FlashSale.ProcessWorker").Contains($idC))

        # ---------- nothing left behind ----------
        $all = $queues + @($queues | ForEach-Object { "$_.dlq" })
        $empty = Wait-Until { @($all | Where-Object { $q = Mq "/queues/%2F/$_"; $null -ne $q -and [int]$q.messages -ne 0 }).Count -eq 0 } 20
        Check "every queue and every DLQ is empty at the end" $empty (($all | ForEach-Object { $q = Mq "/queues/%2F/$_"; if ($q) { "$_=$($q.messages)" } }) -join ",")
    }
    catch { Check "unexpected error: $($_.Exception.Message)" $false }
    finally {
        foreach ($sp in $started) {
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$($sp.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $sp.Id -Force -ErrorAction SilentlyContinue
        }
        docker rm -f $mq $redis *> $null
    }
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "The workflow description and sequence diagrams match the implementation." -ForegroundColor Green
