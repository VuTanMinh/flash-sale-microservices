# ============================================================
# Week 11 TP-P04 (docs/metrics.md): every exported Prometheus metric exists on
# the right service, and each injected case moves the right metric by the
# expected amount (Notion 03C C-07). Attempts are counted apart from applied
# business results.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-metrics.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5697/15697) and Redis (6404) against the given PostgreSQL container.
# Services run on ports 5147 (Order), 5148 (Inventory) and 5149 (Worker).
#
# Cases (each reads the counters before and after):
#   A. 3 normal orders: accepted +3, outcome{Completed} +3,
#      stock_decisions{reserved} +3, Worker attempts +3.
#   B. A stock rejection: outcome{Rejected} +1, stock_decisions{rejected} +1.
#   C. A duplicate StockReserved (same MessageId): duplicates{StockResult} +1;
#      the Confirmed outcome count is unchanged.
#   D. A transient fault (Order's Inbox INSERT revoked ~2 s):
#      retries{StockResult} >= 1, no new dead letter.
#   E. A poison StockReserved (empty MessageId):
#      dead_lettered{StockResult,invalid} +1.
#   F. An early completion (order still PendingStock): requeued_early +1.
#   G. Broker paused while an order is placed: outbox_unpublished >= 1 and
#      oldest_unpublished_age_seconds > 0, then both back to 0 after unpause.
#   H. Worker replay of a completed order's StockReserved: Worker attempts +1;
#      Order's completion Inbox rows unchanged (duplicates absorbed).
#   I. Every metric docs/metrics.md lists as exported is present on its
#      service; no metric uses an order id or message id as a label value.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 17     # number of Check calls in the try block (a truncated run must fail)
$mq = "verify-me-mq"; $amqp = 5697; $mgmt = 15697; $redis = "verify-me-redis"; $redisPort = 6404
$orderPort = 5147; $invPort = 5148; $workerPort = 5149
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__Enabled = "false" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}   # project -> current log file
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "me-$runId"                     # warmed product, used by every real order
$initialStock = 20
$cStartedAt = "2000-01-01T00:00:00Z" # case C: a crafted Worker start time clearly earlier than the confirmation, to exercise the R1 clamp
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessingStarted.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"
$retryQueues = "OrderProcessingStarted.retry.1", "OrderProcessingStarted.retry.2", "OrderProcessingStarted.retry.3", "OrderProcessed.retry.1", "OrderProcessed.retry.2", "OrderProcessed.retry.3"

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
function QueueCount([string]$q) { return (QueueDepth $q) }
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
    $log = Join-Path $env:TEMP "verify-me-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "me-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function Ts([string]$id, [string]$col) { return (Sql "SELECT coalesce(to_char(`"$col`", 'YYYY-MM-DD HH24:MI:SS.US'), '-') FROM order_service.orders WHERE `"Id`" = '$id';") }
function OrdInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function AllCompleted([string[]]$ids) { foreach ($id in $ids) { if ((State $id) -ne "Completed") { return $false } }; return $true }
function Publish([string]$eventType, [string]$payload) {
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $eventType; content_type = "application/json" }; routing_key = $eventType; payload = $payload; payload_encoding = "string" } | Out-Null
}
function OrderProcessedPayload([string]$orderId, [string]$startedAt) {
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$orderId`",`"CorrelationId`":`"verify-processing`",`"ProcessingStartedAt`":`"$startedAt`"}"
}
function OrderProcessingStartedPayload([string]$orderId, [string]$messageId, [string]$startedAt) {
    return "{`"OrderId`":`"$orderId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-processing`",`"StartedAt`":`"$startedAt`"}"
}
function StockReservedPayload([string]$orderId, [string]$messageId, [string]$productId) {
    return "{`"OrderId`":`"$orderId`",`"ProductId`":`"$productId`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-processing`"}"
}
# The start event's MessageId is derived deterministically from the OrderId:
# SHA-1 over the fixed namespace GUID bytes + the OrderId bytes, version-5 /
# RFC 4122 variant bits, matching OrderProcessingStartedEto.DeriveMessageId.
function DeriveStartMessageId([string]$orderId) {
    $ns = [Guid]::Parse("9e1b5c2a-3d4f-4a6b-8c7d-0e9f1a2b3c4d").ToByteArray()
    $name = [Guid]::Parse($orderId).ToByteArray()
    $buffer = New-Object byte[] ($ns.Length + $name.Length)
    [Array]::Copy($ns, 0, $buffer, 0, $ns.Length)
    [Array]::Copy($name, 0, $buffer, $ns.Length, $name.Length)
    $hash = ([Security.Cryptography.SHA1]::Create()).ComputeHash($buffer)
    $uuid = New-Object byte[] 16
    [Array]::Copy($hash, 0, $uuid, 0, 16)
    $uuid[6] = ($uuid[6] -band 0x0F) -bor 0x50
    $uuid[8] = ($uuid[8] -band 0x3F) -bor 0x80
    return ([Guid]::new($uuid)).ToString()
}
# One row per history entry, "FromState|ToState|MessageId|Implied|At", ordered
# by the database-assigned insertion key Seq. '-' means NULL.
function HistoryRows([string]$id) {
    $sql = "SELECT coalesce(`"FromState`",'-') || '|' || `"ToState`" || '|' || coalesce(`"MessageId`"::text,'-') || '|' || `"Implied`"::text || '|' || to_char(`"At`", 'YYYY-MM-DD HH24:MI:SS.US') FROM order_service.order_status_history WHERE `"OrderId`" = '$id' ORDER BY `"Seq`";"
    return @((Sql $sql) -split "`n" | Where-Object { $_ -ne "" })
}
function HistoryCount([string]$id) { return (Int1 "SELECT count(*) FROM order_service.order_status_history WHERE `"OrderId`" = '$id';") }
function ApiHistory([string]$id) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing "http://localhost:$orderPort/api/orders/$id" -TimeoutSec 10
        return @(($r.Content | ConvertFrom-Json).history)
    } catch { return @() }
}
function AllDlqsEmpty() { foreach ($q in $allDlqs) { if ((QueueCount $q) -ne 0) { return $false } }; return $true }

# ================================================================== run
try {
    # ---------------------------------------------------------- guards
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5147-5149" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-me-definitions.json"; $conf = Join-Path $env:TEMP "verify-me-rabbitmq.conf"
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
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = $initialStock } -Force *> $null
    Check "warm-up: $p has $initialStock units" ((Stock $p) -eq "$initialStock")

    # ---------------------------------------------------------- metric helpers
    $ports = @{ "FlashSale.OrderService" = $orderPort; "FlashSale.InventoryService" = $invPort; "FlashSale.ProcessWorker" = $workerPort }
    function Scrape([string]$project) {
        try { return (Invoke-WebRequest -UseBasicParsing "http://localhost:$($ports[$project])/metrics" -TimeoutSec 10).Content } catch { return "" }
    }
    # Sum of every sample of $name whose label text contains all of $labels
    # (for example 'consumer="StockResult"'). Returns 0 when there is no sample.
    function MetricValue([string]$project, [string]$name, [string[]]$labels = @()) {
        $sum = 0.0
        foreach ($line in ((Scrape $project) -split "`n")) {
            if ($line.StartsWith("#")) { continue }
            if ($line -notmatch "^$([regex]::Escape($name))(\{([^}]*)\})?\s+(\S+)") { continue }
            $lab = $Matches[2]
            $ok = $true
            foreach ($l in $labels) { if (-not $lab -or -not $lab.Contains($l)) { $ok = $false } }
            if ($ok) { $sum += [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture) }
        }
        return $sum
    }
    function MetricExists([string]$project, [string]$name) {
        return ((Scrape $project) -match "(?m)^# TYPE $([regex]::Escape($name)) ")
    }
    function ResultMsg([string]$orderId) {
        return (Sql "SELECT coalesce(`"Payload`"->>'MessageId','-') FROM inventory_service.outbox_events WHERE `"OrderId`" = '$orderId' LIMIT 1;")
    }
    $pRej = "me-rej-$runId"
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $pRej = 0 } -Force *> $null
    Check "warm-up: $pRej is open with 0 units" ((Stock $pRej) -eq "0")

    # ---------------------------------------------------------- A. normal orders
    Write-Output "== A. Three normal orders"
    $accBefore = MetricValue "FlashSale.OrderService" "flashsale_orders_accepted_total"
    $compBefore = MetricValue "FlashSale.OrderService" "flashsale_orders_outcome_total" @('outcome="Completed"')
    $resBefore = MetricValue "FlashSale.InventoryService" "flashsale_stock_decisions_total" @('outcome="reserved"')
    $wrkBefore = MetricValue "FlashSale.ProcessWorker" "flashsale_orders_processed_total"
    $aOrders = @(); for ($i = 0; $i -lt 3; $i++) { $id = Post-Order $p ("me-a-$i-" + [guid]::NewGuid()); if ($id) { $aOrders += $id } }
    $aDone = Wait-Until { AllCompleted $aOrders } 60
    Start-Sleep 2
    $accD = (MetricValue "FlashSale.OrderService" "flashsale_orders_accepted_total") - $accBefore
    $compD = (MetricValue "FlashSale.OrderService" "flashsale_orders_outcome_total" @('outcome="Completed"')) - $compBefore
    $resD = (MetricValue "FlashSale.InventoryService" "flashsale_stock_decisions_total" @('outcome="reserved"')) - $resBefore
    $wrkD = (MetricValue "FlashSale.ProcessWorker" "flashsale_orders_processed_total") - $wrkBefore
    Check "A: 3 orders completed" ($aOrders.Count -eq 3 -and $aDone) "orders=$($aOrders.Count) done=$aDone"
    Check "A: accepted +3, outcome{Completed} +3, stock_decisions{reserved} +3, Worker attempts +3" ($accD -eq 3 -and $compD -eq 3 -and $resD -eq 3 -and $wrkD -eq 3) "accepted=+$accD completed=+$compD reserved=+$resD worker=+$wrkD"

    # ---------------------------------------------------------- B. rejection
    Write-Output "== B. A stock rejection"
    $rejBefore = MetricValue "FlashSale.OrderService" "flashsale_orders_outcome_total" @('outcome="Rejected"')
    $decRejBefore = MetricValue "FlashSale.InventoryService" "flashsale_stock_decisions_total" @('outcome="rejected"')
    $bId = Post-Order $pRej ("me-b-" + [guid]::NewGuid())
    $bDone = Wait-Until { (State $bId) -eq "Rejected" } 60
    Start-Sleep 1
    $rejD = (MetricValue "FlashSale.OrderService" "flashsale_orders_outcome_total" @('outcome="Rejected"')) - $rejBefore
    $decRejD = (MetricValue "FlashSale.InventoryService" "flashsale_stock_decisions_total" @('outcome="rejected"')) - $decRejBefore
    Check "B: outcome{Rejected} +1 and stock_decisions{rejected} +1" ($bDone -and $rejD -eq 1 -and $decRejD -eq 1) "state=$(State $bId) rejected=+$rejD decisions-rejected=+$decRejD"

    # ---------------------------------------------------------- C. duplicate result
    Write-Output "== C. A duplicate StockReserved (same MessageId)"
    $cOrder = $aOrders[0]
    $cMsg = ResultMsg $cOrder
    $dupBefore = MetricValue "FlashSale.OrderService" "flashsale_consumer_duplicates_total" @('consumer="StockResult"')
    $confBefore = MetricValue "FlashSale.OrderService" "flashsale_orders_outcome_total" @('outcome="Confirmed"')
    Publish "StockReserved" (StockReservedPayload $cOrder $cMsg $p)
    $cOk = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_consumer_duplicates_total" @('consumer="StockResult"')) -ge ($dupBefore + 1) } 20
    $dupD = (MetricValue "FlashSale.OrderService" "flashsale_consumer_duplicates_total" @('consumer="StockResult"')) - $dupBefore
    $confD = (MetricValue "FlashSale.OrderService" "flashsale_orders_outcome_total" @('outcome="Confirmed"')) - $confBefore
    Check "C: duplicates{StockResult} +1 and the Confirmed outcome is unchanged" ($cOk -and $dupD -eq 1 -and $confD -eq 0) "duplicates=+$dupD confirmed=+$confD"

    # ---------------------------------------------------------- D. transient fault
    Write-Output "== D. A transient fault (Order Inbox INSERT revoked ~2 s)"
    $retBefore = MetricValue "FlashSale.OrderService" "flashsale_consumer_retries_total" @('consumer="StockResult"')
    $dlBefore = MetricValue "FlashSale.OrderService" "flashsale_consumer_dead_lettered_total" @('consumer="StockResult"')
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $dId = Post-Order $p ("me-d-" + [guid]::NewGuid())
    $dRetried = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_consumer_retries_total" @('consumer="StockResult"')) -ge ($retBefore + 1) } 15
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    $dDone = Wait-Until { (State $dId) -eq "Completed" } 60
    $retD = (MetricValue "FlashSale.OrderService" "flashsale_consumer_retries_total" @('consumer="StockResult"')) - $retBefore
    $dlD = (MetricValue "FlashSale.OrderService" "flashsale_consumer_dead_lettered_total" @('consumer="StockResult"')) - $dlBefore
    Check "D: retries{StockResult} >= 1, the order completes, no new dead letter" ($dRetried -and $dDone -and $retD -ge 1 -and $dlD -eq 0) "retries=+$retD dead-lettered=+$dlD state=$(State $dId)"

    # ---------------------------------------------------------- E. poison
    Write-Output "== E. A poison StockReserved (empty MessageId)"
    $invBefore = MetricValue "FlashSale.OrderService" "flashsale_consumer_dead_lettered_total" @('consumer="StockResult"', 'reason="invalid"')
    Publish "StockReserved" (StockReservedPayload ([guid]::NewGuid().ToString()) "00000000-0000-0000-0000-000000000000" $p)
    $eOk = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_consumer_dead_lettered_total" @('consumer="StockResult"', 'reason="invalid"')) -ge ($invBefore + 1) } 20
    $invD = (MetricValue "FlashSale.OrderService" "flashsale_consumer_dead_lettered_total" @('consumer="StockResult"', 'reason="invalid"')) - $invBefore
    Check "E: dead_lettered{StockResult,invalid} +1" ($eOk -and $invD -eq 1) "invalid=+$invD"

    # ---------------------------------------------------------- F. early completion
    Write-Output "== F. An early completion (order still PendingStock)"
    Stop-Svc "FlashSale.InventoryService"
    $fId = Post-Order $p ("me-f-" + [guid]::NewGuid())
    $earlyBefore = MetricValue "FlashSale.OrderService" "flashsale_consumer_requeued_early_total" @('consumer="OrderProcessed"')
    Publish "OrderProcessed" (OrderProcessedPayload $fId (Get-Date).ToUniversalTime().ToString("o"))
    $fOk = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_consumer_requeued_early_total" @('consumer="OrderProcessed"')) -ge ($earlyBefore + 1) } 20
    $earlyD = (MetricValue "FlashSale.OrderService" "flashsale_consumer_requeued_early_total" @('consumer="OrderProcessed"')) - $earlyBefore
    Check "F: requeued_early{OrderProcessed} >= 1 while the order is PendingStock" ($fOk -and $earlyD -ge 1 -and (State $fId) -eq "PendingStock") "requeued-early=+$earlyD state=$(State $fId)"
    Start-Svc "FlashSale.InventoryService" "f"
    $fDone = Wait-Until { (State $fId) -eq "Completed" } 90

    # ---------------------------------------------------------- G. outbox backlog
    Write-Output "== G. Broker paused while an order is placed (Outbox backlog gauges)"
    docker pause $mq *> $null
    $gId = Post-Order $p ("me-g-" + [guid]::NewGuid())
    $gBacklog = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_outbox_unpublished") -ge 1 -and (MetricValue "FlashSale.OrderService" "flashsale_outbox_oldest_unpublished_age_seconds") -gt 0 } 30
    $gUnpub = MetricValue "FlashSale.OrderService" "flashsale_outbox_unpublished"
    $gAge = MetricValue "FlashSale.OrderService" "flashsale_outbox_oldest_unpublished_age_seconds"
    docker unpause $mq *> $null
    Check "G: while the broker is paused, outbox_unpublished >= 1 and the oldest age > 0" ($gId -ne "" -and $gBacklog) "unpublished=$gUnpub oldest-age=$gAge"
    $gDrained = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_outbox_unpublished") -eq 0 -and (MetricValue "FlashSale.OrderService" "flashsale_outbox_oldest_unpublished_age_seconds") -eq 0 } 90
    $gDone = Wait-Until { (State $gId) -eq "Completed" } 90
    Check "G: after the broker is back, both gauges return to 0 and the order completes" ($gDrained -and $gDone) "unpublished=$(MetricValue 'FlashSale.OrderService' 'flashsale_outbox_unpublished') oldest-age=$(MetricValue 'FlashSale.OrderService' 'flashsale_outbox_oldest_unpublished_age_seconds') state=$(State $gId)"

    # ---------------------------------------------------------- H. worker replay
    Write-Output "== H. Worker replay of a completed order's StockReserved"
    $hOrder = $aOrders[1]
    $hMsg = ResultMsg $hOrder
    $wrkBefore = MetricValue "FlashSale.ProcessWorker" "flashsale_orders_processed_total"
    $inboxBefore = OrdInbox $hOrder
    $dupDoneBefore = MetricValue "FlashSale.OrderService" "flashsale_consumer_duplicates_total" @('consumer="OrderProcessed"')
    Mq Post "/exchanges/%2F/amq.default/publish" @{ properties = @{ type = "StockReserved"; content_type = "application/json" }; routing_key = "ProcessWorker.StockReserved"; payload = (StockReservedPayload $hOrder $hMsg $p); payload_encoding = "string" } | Out-Null
    $hOk = Wait-Until { (MetricValue "FlashSale.OrderService" "flashsale_consumer_duplicates_total" @('consumer="OrderProcessed"')) -ge ($dupDoneBefore + 1) } 30
    $wrkD = (MetricValue "FlashSale.ProcessWorker" "flashsale_orders_processed_total") - $wrkBefore
    Check "H: Worker attempts +1, but Order's completion Inbox rows stay at 1 (the copy is a duplicate)" ($hOk -and $wrkD -eq 1 -and $inboxBefore -eq 1 -and (OrdInbox $hOrder) -eq 1) "worker=+$wrkD completion-inbox=$inboxBefore->$(OrdInbox $hOrder)"

    # ---------------------------------------------------------- I. exports present, no id labels
    Write-Output "== I. Exports"
    $expected = [ordered]@{
        "FlashSale.OrderService" = @("flashsale_orders_accepted_total", "flashsale_orders_outcome_total", "flashsale_reconciliation_retriggers_total", "flashsale_reconciliation_given_up_total", "flashsale_reconciliation_stuck_orders", "flashsale_consumer_retries_total", "flashsale_consumer_duplicates_total", "flashsale_consumer_dead_lettered_total", "flashsale_consumer_requeued_early_total", "flashsale_outbox_unpublished", "flashsale_outbox_oldest_unpublished_age_seconds", "process_cpu_seconds_total", "process_working_set_bytes")
        "FlashSale.InventoryService" = @("flashsale_stock_decisions_total", "flashsale_consumer_retries_total", "flashsale_consumer_duplicates_total", "flashsale_consumer_dead_lettered_total", "flashsale_outbox_unpublished", "flashsale_outbox_oldest_unpublished_age_seconds", "process_cpu_seconds_total", "process_working_set_bytes")
        "FlashSale.ProcessWorker" = @("flashsale_orders_processed_total", "flashsale_process_worker_dead_lettered_total", "flashsale_process_worker_duration_seconds", "flashsale_consumer_retries_total", "flashsale_consumer_dead_lettered_total", "process_cpu_seconds_total", "process_working_set_bytes")
    }
    foreach ($proj in $expected.Keys) {
        $missing = @($expected[$proj] | Where-Object { -not (MetricExists $proj $_) })
        Check "I: $proj exports every metric docs/metrics.md lists for it ($($expected[$proj].Count))" ($missing.Count -eq 0) "missing: $($missing -join ', ')"
    }
    $idLabels = @()
    foreach ($proj in $expected.Keys) {
        foreach ($line in ((Scrape $proj) -split "`n")) {
            if (-not $line.StartsWith("#") -and $line -match '\{[^}]*"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"') { $idLabels += "$proj : $line" }
        }
    }
    Check "I: no metric uses an order id or message id as a label value" ($idLabels.Count -eq 0) ((@($idLabels) | Select-Object -First 3) -join " | ")
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    docker unpause $mq *> $null
    foreach ($project in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $project }
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: every exported metric is present and each injected case moved it by the expected amount."
exit 0
