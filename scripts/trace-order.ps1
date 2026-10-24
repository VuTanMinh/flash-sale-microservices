# ============================================================
# Week 11 TP-P03 (docs/metrics.md "Stage timestamp schema"): trace one order
# across all three services by CorrelationId, OrderId and MessageId, and its
# stage timestamps.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\trace-order.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5696/15696) and Redis (6403) against the given PostgreSQL container.
# Services run on ports 5144 (Order), 5145 (Inventory) and 5146 (Worker).
#
# Three orders, each with its own X-Correlation-ID (Notion 03C C-05):
#   ok     - a success: reserved, processed, Completed;
#   reject - a stock rejection (product warmed with 0 units): Rejected;
#   fault  - a recovered fault: Order's Inbox INSERT is revoked for ~3 s, so
#            StockReserved is retried and then applied; Completed.
# For each order the script collects every JSON log line with that
# CorrelationId from all three services (src/<Service>/Logs/logs.json), prints
# the timeline, and checks:
#   1. every expected hop is present;
#   2. the MessageIds link up across services (Order Outbox payload ->
#      Inventory received; Inventory result payload -> Order received and
#      Worker received; start event = derived id, completion = OrderId);
#   3. the stage timestamps from the database are present and in order:
#      acceptance <= publication <= stock decision <= decision applied
#      (<= completion); a missing value FAILs, it is never 0;
#   4. the history rows and the API polling response agree with the state.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 28     # number of Check calls in the try block (a truncated run must fail)
$mq = "verify-tr-mq"; $amqp = 5696; $mgmt = 15696; $redis = "verify-tr-redis"; $redisPort = 6403
$orderPort = 5144; $invPort = 5145; $workerPort = 5146
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
$p = "tr-$runId"                     # warmed product, used by every real order
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
    $log = Join-Path $env:TEMP "verify-tr-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "tr-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
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
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5144-5146" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-tr-definitions.json"; $conf = Join-Path $env:TEMP "verify-tr-rabbitmq.conf"
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

    # ---------------------------------------------------------- trace helpers
    $pReject = "tr-rej-$runId"
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $pReject = 0 } -Force *> $null
    Check "warm-up: $pReject is open with 0 units" ((Stock $pReject) -eq "0")

    function JsonLines([string]$project, [string]$cid) {
        $path = Join-Path $repoRoot "src\$project\Logs\logs.json"
        if (-not (Test-Path -LiteralPath $path)) { return @() }
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        $out = @()
        foreach ($line in ($text -split "`n")) {
            if ($line.Contains("`"CorrelationId`":`"$cid`"")) {
                try { $o = $line | ConvertFrom-Json; $o | Add-Member -NotePropertyName Project -NotePropertyValue $project -Force; $out += $o } catch { }
            }
        }
        return $out
    }
    function Trace([string]$cid) {
        $all = @()
        foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { $all += @(JsonLines $proj $cid) }
        return @($all | Sort-Object { [DateTime]::Parse($_.'@t').ToUniversalTime() })
    }
    function Has($lines, [string]$project, [string]$template) { return @($lines | Where-Object { $_.Project -eq $project -and $_.'@mt' -eq $template }).Count -ge 1 }
    function First($lines, [string]$project, [string]$template) { return @($lines | Where-Object { $_.Project -eq $project -and $_.'@mt' -eq $template })[0] }
    function Show($lines, [string]$label) {
        Write-Output "   -- timeline: $label ($(@($lines).Count) log lines)"
        foreach ($l in $lines) {
            $svc = if ($l.Service) { $l.Service } else { $l.Project }
            $msg = "$($l.'@mt')"
            foreach ($prop in $l.PSObject.Properties) { if ($prop.Name -notlike '@*') { $msg = $msg.Replace("{" + $prop.Name + "}", "$($prop.Value)") } }
            Write-Output ("      {0}  {1,-28} {2}" -f $l.'@t', $svc, $msg)
        }
    }
    function OutboxMsg([string]$schema, [string]$orderId, [string]$eventType) {
        return (Sql "SELECT coalesce(`"Payload`"->>'MessageId','-') FROM $schema.outbox_events WHERE `"OrderId`" = '$orderId' AND `"EventType`" = '$eventType' ORDER BY `"CreatedAt`" LIMIT 1;")
    }
    function StageTimes([string]$orderId) {
        $q = "SELECT coalesce(to_char(o.`"RequestAcceptedAt`", 'YYYY-MM-DD HH24:MI:SS.US'),'-') || '|' || " +
             "coalesce((SELECT to_char(min(e.`"PublishedAt`"), 'YYYY-MM-DD HH24:MI:SS.US') FROM order_service.outbox_events e WHERE e.`"OrderId`" = o.`"Id`" AND e.`"EventType`" = 'OrderPlaced'),'-') || '|' || " +
             "coalesce((SELECT to_char(min(i.`"CreatedAt`"), 'YYYY-MM-DD HH24:MI:SS.US') FROM inventory_service.outbox_events i WHERE i.`"OrderId`" = o.`"Id`"),'-') || '|' || " +
             "coalesce(to_char(o.`"ConfirmedOrRejectedAt`", 'YYYY-MM-DD HH24:MI:SS.US'),'-') || '|' || " +
             "coalesce(to_char(o.`"CompletedAt`", 'YYYY-MM-DD HH24:MI:SS.US'),'-') " +
             "FROM order_service.orders o WHERE o.`"Id`" = '$orderId';"
        $v = (Sql $q).Split('|')
        return [pscustomobject]@{ Accepted = $v[0]; Published = $v[1]; Decided = $v[2]; Applied = $v[3]; Completed = $v[4] }
    }
    function Interval([string]$a, [string]$b) {
        if ($a -eq "-" -or $b -eq "-") { return "missing" }
        return ("{0:N1} ms" -f ([DateTime]::Parse($b) - [DateTime]::Parse($a)).TotalMilliseconds)
    }
    function Ordered([string[]]$ts) {
        for ($i = 0; $i -lt $ts.Count; $i++) { if ($ts[$i] -eq "-") { return $false } }
        for ($i = 1; $i -lt $ts.Count; $i++) { if ([DateTime]::Parse($ts[$i]) -lt [DateTime]::Parse($ts[$i - 1])) { return $false } }
        return $true
    }
    function ApiOrder([string]$id) {
        try { return ((Invoke-WebRequest -UseBasicParsing "http://localhost:$orderPort/api/orders/$id" -TimeoutSec 10).Content | ConvertFrom-Json) } catch { return $null }
    }

    # ---------------------------------------------------------- the three orders
    $cidOk = "trace-ok-$runId"; $cidRej = "trace-reject-$runId"; $cidFault = "trace-fault-$runId"

    Write-Output "== 1. Success"
    $okId = Post-Order $p $cidOk
    Check "ok: order accepted" ($okId -ne "") "order=$okId"
    $okDone = Wait-Until { (State $okId) -eq "Completed" } 60

    Write-Output "== 2. Stock rejection"
    $rejId = Post-Order $pReject $cidRej
    Check "reject: order accepted" ($rejId -ne "") "order=$rejId"
    $rejDone = Wait-Until { (State $rejId) -eq "Rejected" } 60

    Write-Output "== 3. Recovered fault (Order Inbox INSERT revoked ~3 s)"
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $faultId = Post-Order $p $cidFault
    $retried = Wait-Until { @(JsonLines "FlashSale.OrderService" $cidFault | Where-Object { $_.'@mt' -like "Failed to process {EventType}*retrying in {Delay}" }).Count -ge 1 } 20
    Start-Sleep 2
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    Check "fault: order accepted and a retry happened while the grant was revoked" ($faultId -ne "" -and $retried) "order=$faultId retried=$retried"
    $faultDone = Wait-Until { (State $faultId) -eq "Completed" } 60
    Start-Sleep 2   # let the last log lines flush

    foreach ($case in @(
            @{ Name = "ok"; Id = $okId; Cid = $cidOk; Done = $okDone; Final = "Completed"; Success = $true; Fault = $false },
            @{ Name = "reject"; Id = $rejId; Cid = $cidRej; Done = $rejDone; Final = "Rejected"; Success = $false; Fault = $false },
            @{ Name = "fault"; Id = $faultId; Cid = $cidFault; Done = $faultDone; Final = "Completed"; Success = $true; Fault = $true })) {
        $n = $case.Name; $id = $case.Id
        Write-Output "== Trace: $n (CorrelationId $($case.Cid), order $id)"
        Check "${n}: final state is $($case.Final)" ($case.Done -and (State $id) -eq $case.Final) "state=$(State $id)"
        $lines = Trace $case.Cid
        Show $lines $n

        # 1. hops present
        $hops = [ordered]@{
            "Order Service received the HTTP request" = (Has $lines "FlashSale.OrderService" "Executing endpoint '{EndpointName}'")
            "Inventory received OrderPlaced" = (Has $lines "FlashSale.InventoryService" "Received OrderPlaced {MessageId} for order {OrderId}")
            "Inventory decided" = (Has $lines "FlashSale.InventoryService" "OrderPlaced {OrderId} for product {ProductId} -> {Result}")
            "Order Service received the stock result" = (Has $lines "FlashSale.OrderService" "Received {EventType} {MessageId} for order {OrderId}")
            "Order Service applied the decision" = (Has $lines "FlashSale.OrderService" "Order {OrderId} -> {State}")
        }
        if ($case.Success) {
            $hops["Worker received StockReserved"] = (Has $lines "FlashSale.ProcessWorker" "Received StockReserved {MessageId} for order {OrderId}; starting downstream processing")
            $hops["Worker published the completion"] = (Has $lines "FlashSale.ProcessWorker" "Order {OrderId} processed in {ElapsedMs}ms; published OrderProcessed")
            $hops["Order Service received OrderProcessingStarted"] = (Has $lines "FlashSale.OrderService" "Received OrderProcessingStarted {MessageId} for order {OrderId}")
            $hops["Order Service received OrderProcessed"] = (Has $lines "FlashSale.OrderService" "Received OrderProcessed {MessageId} for order {OrderId}")
            $hops["Order Service completed the order"] = (Has $lines "FlashSale.OrderService" "Order {OrderId} -> Completed")
        } else {
            $hops["no Worker line (a rejected order never reaches the Worker)"] = (@($lines | Where-Object { $_.Project -eq "FlashSale.ProcessWorker" -and $_.'@mt' -like "Received StockReserved*" }).Count -eq 0)
        }
        if ($case.Fault) {
            $retryLines = @($lines | Where-Object { $_.Project -eq "FlashSale.OrderService" -and $_.'@mt' -like "Failed to process {EventType}*retrying in {Delay}" })
            $hops["Order Service logged the retry with its attempt number"] = ($retryLines.Count -ge 1 -and "$($retryLines[0].Attempt)" -eq "1")
        }
        $missing = @($hops.Keys | Where-Object { -not $hops[$_] })
        Check "${n}: every expected hop is in the trace ($($hops.Count) hops)" ($missing.Count -eq 0) "missing: $($missing -join '; ')"
        $svcCount = @($lines | Where-Object { $_.Service } | ForEach-Object { $_.Service } | Sort-Object -Unique).Count
        $wantSvc = if ($case.Success) { 3 } else { 2 }
        Check "${n}: the same CorrelationId appears in $wantSvc services' logs, each line tagged with its Service" ($svcCount -eq $wantSvc) "services=$svcCount"

        # 2. ids link up
        $placedMsg = OutboxMsg "order_service" $id "OrderPlaced"
        $resultType = if ($case.Success) { "StockReserved" } else { "StockRejected" }
        $resultMsg = OutboxMsg "inventory_service" $id $resultType
        $invRecv = First $lines "FlashSale.InventoryService" "Received OrderPlaced {MessageId} for order {OrderId}"
        $ordRecv = First $lines "FlashSale.OrderService" "Received {EventType} {MessageId} for order {OrderId}"
        $idOk = ($placedMsg -ne "-" -and "$($invRecv.MessageId)" -eq $placedMsg -and "$($invRecv.OrderId)" -eq $id) -and
                ($resultMsg -ne "-" -and "$($ordRecv.MessageId)" -eq $resultMsg -and "$($ordRecv.EventType)" -eq $resultType)
        $idDetail = "OrderPlaced outbox=$placedMsg inventory-received=$($invRecv.MessageId); $resultType outbox=$resultMsg order-received=$($ordRecv.MessageId)"
        if ($case.Success) {
            $wRecv = First $lines "FlashSale.ProcessWorker" "Received StockReserved {MessageId} for order {OrderId}; starting downstream processing"
            $startRecv = First $lines "FlashSale.OrderService" "Received OrderProcessingStarted {MessageId} for order {OrderId}"
            $doneRecv = First $lines "FlashSale.OrderService" "Received OrderProcessed {MessageId} for order {OrderId}"
            $idOk = $idOk -and ("$($wRecv.MessageId)" -eq $resultMsg) -and ("$($startRecv.MessageId)" -eq (DeriveStartMessageId $id)) -and ("$($doneRecv.MessageId)" -eq $id)
            $idDetail += "; worker-received=$($wRecv.MessageId); start=$($startRecv.MessageId) (derived $(DeriveStartMessageId $id)); completion=$($doneRecv.MessageId)"
        }
        Check "${n}: the MessageIds link up across services" $idOk $idDetail

        # 3. stage timestamps
        $st = StageTimes $id
        # Invariants: acceptance <= publication, and acceptance <= decision <=
        # applied (<= completion). Publication is NOT required to precede the
        # decision: PublishedAt is set after the broker's confirm, so the
        # consumer can decide before the publisher marks the row (Notion 04,
        # docs/metrics.md). That case is reported as a visible anomaly.
        $chain = @($st.Accepted, $st.Decided, $st.Applied)
        if ($case.Success) { $chain += $st.Completed }
        Write-Output "   -- stage timestamps: accepted=$($st.Accepted) published=$($st.Published) decided=$($st.Decided) applied=$($st.Applied) completed=$($st.Completed)"
        Write-Output "   -- intervals: accept->publish $(Interval $st.Accepted $st.Published); accept->decide $(Interval $st.Accepted $st.Decided); decide->apply $(Interval $st.Decided $st.Applied)$(if ($case.Success) { "; apply->complete $(Interval $st.Applied $st.Completed); accept->complete $(Interval $st.Accepted $st.Completed)" })"
        if ($st.Published -ne "-" -and $st.Decided -ne "-" -and [DateTime]::Parse($st.Published) -gt [DateTime]::Parse($st.Decided)) {
            Write-Output "   -- anomaly (expected, see docs/metrics.md): PublishedAt trails the decision by $(Interval $st.Decided $st.Published); the row is marked after the broker confirm"
        }
        Check "${n}: every stage timestamp is present; acceptance <= publication and acceptance <= decision <= applied$(if ($case.Success) { ' <= completion' })" ((Ordered $chain) -and (Ordered @($st.Accepted, $st.Published))) "$($st.Accepted) / pub $($st.Published) / $(($chain | Select-Object -Skip 1) -join ' / ')"
        if (-not $case.Success) { Check "${n}: a rejected order has no completion time" ($st.Completed -eq "-") "completed=$($st.Completed)" }

        # 4. history and API
        $rows = HistoryRows $id
        $toStates = @($rows | ForEach-Object { $_.Split('|')[1] })
        $wantStates = if ($case.Success) { @("PendingStock", "Confirmed", "Processing", "Completed") } else { @("PendingStock", "Rejected") }
        Check "${n}: the history (by Seq) is $($wantStates -join ' -> ')" (($toStates -join ",") -eq ($wantStates -join ",")) "history=$($toStates -join ',')"
        $api = ApiOrder $id
        $apiStates = @($api.history | ForEach-Object { "$($_.to)" })
        Check "${n}: the API polling response shows the same state and history" ($null -ne $api -and "$($api.state)" -eq $case.Final -and ($apiStates -join ",") -eq ($wantStates -join ",")) "api-state=$($api.state) api-history=$($apiStates -join ',')"
    }
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    foreach ($project in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $project }
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: three orders traced across all services by CorrelationId, OrderId and MessageId, with their stage timestamps."
exit 0
