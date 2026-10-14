# ============================================================
# Week 10 TP-F02 (docs/failure-handling.md, "Reconciliation"): a stuck
# PendingStock order is detected, a known outcome (a result Inventory already
# published but Order Service lost) is recovered without a second deduction or
# a new result, reconciliation is bounded with an explicit alert, and stock
# outcomes survive an Order Service restart.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-reconciliation.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5691/15691) and Redis (6400) against the given PostgreSQL container,
# with short reconciliation timeouts (PollIntervalSeconds=2, MaxAttempts=3;
# StuckTimeoutSeconds per case). Cases:
#
#   A. Lost result, recovered: a reserved order whose StockReserved was
#      dead-lettered and the DLQ purged. Reconciliation detects it, Inventory
#      re-sends the SAME stored result (original MessageId), and the order ends
#      Completed with exactly one deduction and no extra result row.
#   B. Transient interruption, drains: stop Inventory, place orders, wait past
#      the timeout, restart Inventory only. Retained work drains; one outcome
#      and one deduction per order; none invented as Rejected.
#   C. Permanent fault, explicit alert: Inventory stays down. After MaxAttempts
#      re-triggers the order is no longer re-triggered, the Error is logged once,
#      the metrics show it given up and unresolved, and it stays PendingStock.
#   D. Order Service restart: restart Order Service while an order is stuck.
#      Reconciliation resumes from the database; the attempt count is not reset
#      beyond its bound; the final outcome is preserved.
#   E. No false positives: a normally completed order is never re-triggered.
#   F. Outcome preserved: once Inventory returns, C and D drain to Completed
#      with one deduction and one result row each; the stuck gauge returns to 0
#      and stock conservation holds (20 - 7 = 13).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-rc-mq"; $amqp = 5691; $mgmt = 15691; $redis = "verify-rc-redis"; $redisPort = 6400
$orderPort = 5135; $invPort = 5136; $workerPort = 5137
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$poll = 2; $maxAttempts = 3
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__PollIntervalSeconds = "$poll"; Reconciliation__MaxAttempts = "$maxAttempts"; Reconciliation__StuckTimeoutSeconds = "5" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "rc-$runId"
$mainQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed", "ProcessWorker.StockReserved"
$dlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"

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
    $log = Join-Path $env:TEMP "verify-rc-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Start-Order([int]$stuckSeconds, [string]$tag) {
    $svcEnv["FlashSale.OrderService"]["Reconciliation__StuckTimeoutSeconds"] = "$stuckSeconds"
    Start-Svc "FlashSale.OrderService" $tag
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "rc-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function OrdInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function InvOutbox([string]$id) { return (Int1 "SELECT count(*) FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id';") }
function ResultMessageId([string]$id) { return (Sql "SELECT `"Payload`"->>'MessageId' FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id' LIMIT 1;") }
function ResultPublishedAt([string]$id) { return (Sql "SELECT coalesce(to_char(`"PublishedAt`", 'YYYY-MM-DD HH24:MI:SS.US'), '-') FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id' LIMIT 1;") }
function OrderPlacedCount([string]$id) { return (Int1 "SELECT count(*) FROM order_service.outbox_events WHERE `"OrderId`" = '$id' AND `"EventType`" = 'OrderPlaced';") }
function Stock([string]$product) { return (Redis "GET", "inventory:$product") }
function Reserved([string]$product) { return (Redis "SCARD", "processed:$product") }
function LogLinesWith([string]$project, [string]$orderId, [string]$needle) {
    $text = Log $project
    if (-not $text) { return 0 }
    return @($text -split "`r?`n" | Where-Object { $_.Contains($orderId) -and $_.Contains($needle) }).Count
}
function Metric([string]$name) {
    try {
        $text = (Invoke-WebRequest -UseBasicParsing "http://localhost:$orderPort/metrics" -TimeoutSec 10).Content
        foreach ($l in ($text -split "`r?`n")) {
            if ($l.StartsWith("#")) { continue }
            if ($l.StartsWith("$name ")) { return ($l -split "\s+")[-1] }
        }
        return ""
    } catch { return "" }
}
function MetricNum([string]$name) {
    $v = Metric $name
    if ($v -eq "") { return -1 }
    return [double]$v
}
function Purge([string]$q) { Mq Delete "/queues/%2F/$q/contents" | Out-Null }

try {
    # ---------------------------------------------------------- guards
    Write-Host "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5135-5137" }
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
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    # Case A needs a long stuck-timeout so reconciliation cannot fire while the
    # lost StockReserved is still going through Order Service's retry ladder.
    Start-Order 20 "a"
    Start-Svc "FlashSale.InventoryService" "a"
    Start-Svc "FlashSale.ProcessWorker" "a"
    $all = $mainQueues + $dlqs
    $ready = Wait-Until { @($all | Where-Object { -not (QueueExists $_) }).Count -eq 0 } 120
    Check "all three services up; every queue and DLQ declared" $ready (($all | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 20 } -Force *> $null
    Check "warm-up: $p has 20 units" ((Stock $p) -eq "20")

    # ======================================================== A. lost result, recovered
    Write-Host "== A. Lost result recovered (StockReserved dead-lettered, DLQ purged)"
    $stockBefore = [int](Stock $p)
    # Refuse Order Service's Inbox insert BEFORE the order is placed, so its
    # StockReserved consumer retries and dead-letters the real result -- the
    # "lost result" this case recovers.
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $a = Post-Order $p ("rc-a-" + [guid]::NewGuid())
    if (-not $a) { throw "SETUP ERROR: could not place order A" }
    $reserved = Wait-Until { (InvOutbox $a) -eq 1 -and [int](Stock $p) -eq ($stockBefore - 1) } 40
    $originalMsg = ResultMessageId $a
    $lost = Wait-Until { (QueueCount "StockReserved.dlq") -ge 1 } 60
    $publishedBeforePurge = ResultPublishedAt $a
    Purge "StockReserved.dlq"
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    Check "A. lost result: Inventory reserved once and published a result before the purge" ($reserved -and $originalMsg -ne "") "stock=$(Stock $p) msg=$originalMsg"
    Check "A. lost result: the StockReserved was dead-lettered (then purged)" $lost "dlq-before-purge=$lost"

    $recovered = Wait-Until { (State $a) -eq "Completed" } 90
    Check "A. lost result: the order ends Completed (reconciled then closed out)" ($recovered -and (State $a) -eq "Completed") "state=$(State $a)"
    Check "A. lost result: exactly one deduction, original result MessageId, one result row" (
        [int](Stock $p) -eq ($stockBefore - 1) -and (Reserved $p) -eq "1" -and (InvOutbox $a) -eq 1 -and (ResultMessageId $a) -eq $originalMsg) "stock=$(Stock $p) reserved=$(Reserved $p) rows=$(InvOutbox $a) msg=$(ResultMessageId $a)"
    Check "A. lost result: Order Service applied the ORIGINAL result MessageId (not a new one)" ((OrdInbox $originalMsg) -eq 1) "inbox=$(OrdInbox $originalMsg)"
    Check "A. lost result: the stored result was actually re-sent (PublishedAt re-stamped after the purge)" ($publishedBeforePurge -ne "-" -and (ResultPublishedAt $a) -ne "-" -and (ResultPublishedAt $a) -ne $publishedBeforePurge) "before=$publishedBeforePurge after=$(ResultPublishedAt $a)"
    Check "A. lost result: Order Service logged the re-trigger for the order" ((LogLinesWith "FlashSale.OrderService" $a "re-publishing OrderPlaced") -ge 1)
    Check "A. lost result: Inventory logged the stored-result re-publication for the order" ((LogLinesWith "FlashSale.InventoryService" $a "re-queuing it for re-publication") -ge 1)

    # ======================================================== B. transient interruption, drains
    Write-Host "== B. Transient interruption (Inventory stopped, then restarted only)"
    Stop-Svc "FlashSale.OrderService"
    Start-Order 5 "b"
    Stop-Svc "FlashSale.InventoryService"
    $bOrders = @()
    for ($i = 0; $i -lt 3; $i++) {
        $o = Post-Order $p ("rc-b-" + [guid]::NewGuid())
        if (-not $o) { throw "SETUP ERROR: could not place order B" }
        $bOrders += $o
    }
    Start-Sleep 8   # past StuckTimeoutSeconds=5: reconciliation may re-trigger each order
    Start-Svc "FlashSale.InventoryService" "b"
    $allCompleted = $true
    foreach ($o in $bOrders) { $allCompleted = $allCompleted -and (Wait-Until { (State $o) -eq "Completed" } 60) }
    Check "B. transient: all three orders drain to Completed after Inventory restarts" $allCompleted (($bOrders | ForEach-Object { "$_=$(State $_)" }) -join ",")
    Check "B. transient: one deduction per order (3 units) and none Rejected" (
        [int](Stock $p) -eq ($stockBefore - 4) -and (Reserved $p) -eq "4" -and
        @($bOrders | Where-Object { (State $_) -eq "Rejected" }).Count -eq 0) "stock=$(Stock $p) reserved=$(Reserved $p)"

    # ======================================================== C. permanent fault, explicit alert
    Write-Host "== C. Permanent fault (Inventory stays down): bounded re-trigger and alert"
    Stop-Svc "FlashSale.OrderService"
    Start-Order 5 "c"
    Stop-Svc "FlashSale.InventoryService"
    $c = Post-Order $p ("rc-c-" + [guid]::NewGuid())
    if (-not $c) { throw "SETUP ERROR: could not place order C" }
    $gaveUp = Wait-Until { (LogLinesWith "FlashSale.OrderService" $c "giving up and surfacing as unresolved") -ge 1 } 90
    Start-Sleep 3
    $cRows = OrderPlacedCount $c
    Check "C. permanent: after MaxAttempts the order stops being re-triggered (1 original + 3 re-triggers)" ($cRows -eq 4) "rows=$cRows"
    Check "C. permanent: the give-up Error is logged exactly once for the order" ((LogLinesWith "FlashSale.OrderService" $c "giving up and surfacing as unresolved") -eq 1) "count=$(LogLinesWith 'FlashSale.OrderService' $c 'giving up and surfacing as unresolved')"
    Check "C. permanent: the order is still PendingStock, never invented as Rejected" ((State $c) -eq "PendingStock") "state=$(State $c)"
    $retrig = MetricNum "flashsale_reconciliation_retriggers_total"
    $givenup = MetricNum "flashsale_reconciliation_given_up_total"
    $stuck = MetricNum "flashsale_reconciliation_stuck_orders"
    Check "C. permanent: metrics count exactly 3 re-triggers, 1 given up, 1 currently stuck" ($retrig -eq 3 -and $givenup -eq 1 -and $stuck -eq 1) "retriggers=$retrig given_up=$givenup stuck=$stuck"
    $stable = OrderPlacedCount $c
    Start-Sleep 7
    Check "C. permanent: no further re-trigger after the give-up" ((OrderPlacedCount $c) -eq $stable) "rows=$stable -> $(OrderPlacedCount $c)"
    Check "C. permanent: the give-up Error is still exactly once after the wait" ((LogLinesWith "FlashSale.OrderService" $c "giving up and surfacing as unresolved") -eq 1) "count=$(LogLinesWith 'FlashSale.OrderService' $c 'giving up and surfacing as unresolved')"

    # ======================================================== D. Order Service restart
    Write-Host "== D. Order Service restart: count is not reset, outcome preserved"
    $d = Post-Order $p ("rc-d-" + [guid]::NewGuid())
    if (-not $d) { throw "SETUP ERROR: could not place order D" }
    Wait-Until { (OrderPlacedCount $d) -ge 2 } 60 | Out-Null   # one re-trigger so far
    Stop-Svc "FlashSale.OrderService"
    Start-Order 5 "d"
    $dResumed = Wait-Until { (OrderPlacedCount $d) -eq 4 } 90
    Check "D. restart: reconciliation resumes from the database and reaches the bound, not reset (1 original + 3 re-triggers)" ($dResumed -and (OrderPlacedCount $d) -eq 4) "rows=$(OrderPlacedCount $d)"
    Check "D. restart: the order is still PendingStock, not Rejected" ((State $d) -eq "PendingStock") "state=$(State $d)"
    Check "D. restart: the resumed log shows the re-trigger for the order" ((LogLinesWith "FlashSale.OrderService" $d "re-publishing OrderPlaced") -ge 1)
    Start-Sleep 9   # one timeout window (5 s) + two polls (2 s each): the count must stay at the bound
    Check "D. restart: the count is still 4 after another timeout window (no 5th re-trigger, not reset)" ((OrderPlacedCount $d) -eq 4) "rows=$(OrderPlacedCount $d)"
    Check "D. restart: the give-up Error is logged for the order in the new process" ((LogLinesWith "FlashSale.OrderService" $d "giving up and surfacing as unresolved") -ge 1)
    $dGivenUp = MetricNum "flashsale_reconciliation_given_up_total"
    $dStuck = MetricNum "flashsale_reconciliation_stuck_orders"
    Check "D. restart: the given-up and stuck metrics are visible" ($dGivenUp -ge 1 -and $dStuck -ge 1) "given_up=$dGivenUp stuck=$dStuck"

    # ======================================================== E. no false positives
    Write-Host "== E. No false positives"
    Start-Svc "FlashSale.InventoryService" "e"
    $e = Post-Order $p ("rc-e-" + [guid]::NewGuid())
    if (-not $e) { throw "SETUP ERROR: could not place order E" }
    $eDone = Wait-Until { (State $e) -eq "Completed" } 60
    Start-Sleep 8   # past StuckTimeoutSeconds=5 + a couple of polls
    Check "E. no false positive: a normally completed order is never re-triggered" ($eDone -and (OrderPlacedCount $e) -eq 1) "state=$(State $e) rows=$(OrderPlacedCount $e)"

    # ======================================================== F. outcome preserved once the dependency returns
    Write-Host "== F. C and D recover once Inventory is back (final outcome preserved)"
    $fC = Wait-Until { (State $c) -eq "Completed" } 90
    $fD = Wait-Until { (State $d) -eq "Completed" } 90
    Check "F. preserved: C and D both reach Completed once Inventory is back" ($fC -and $fD) "c=$(State $c) d=$(State $d)"
    Check "F. preserved: C and D each have exactly one result row" ((InvOutbox $c) -eq 1 -and (InvOutbox $d) -eq 1) "c=$(InvOutbox $c) d=$(InvOutbox $d)"
    Check "F. preserved: neither C nor D is Rejected" ((State $c) -ne "Rejected" -and (State $d) -ne "Rejected")
    $stuckZero = Wait-Until { (MetricNum "flashsale_reconciliation_stuck_orders") -eq 0 } 20
    Check "F. preserved: the stuck gauge returns to 0" $stuckZero "stuck=$(MetricNum 'flashsale_reconciliation_stuck_orders')"
    Check "F. conservation: 20 - 7 = 13, Redis holds exactly the seven completed orders" (
        [int](Stock $p) -eq "13" -and (Reserved $p) -eq "7") "stock=$(Stock $p) reserved=$(Reserved $p)"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user; GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $proj }
    docker rm -f $mq $redis *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Stuck PendingStock is detected, a known outcome is recovered, reconciliation is bounded with an alert, and outcomes survive restart." -ForegroundColor Green
