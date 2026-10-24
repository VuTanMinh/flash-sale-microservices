# ============================================================
# Week 11 TP-P02 (docs/order-state-machine.md): the six-state model's Processing
# state and history, and the success-only interpretation of ProcessingFailed.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-processing.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5695/15695) and Redis (6402) against the given PostgreSQL container.
# Services run on ports 5141 (Order), 5142 (Inventory) and 5143 (Worker).
#
# Cases:
#   A. Normal path: 3 real orders end Completed. Each order takes either the
#      direct path (the start event applied first) or the implied path (the
#      completion applied first): the four transitions in Seq order, At
#      non-decreasing, Implied true only on the Processing row, and the
#      MessageId rule for the path taken (direct: start row MessageId = derived
#      id; implied: Processing row MessageId = OrderId plus a no-op Inbox row
#      for the derived start id). Which path each order took is printed.
#   A2. Deterministic direct path: the Worker is stopped until the order is
#      Confirmed, then started, so the Processing row is NOT implied and carries
#      the derived MessageId.
#   B. Duplicates: the start event and the completion are republished with the
#      same ids, plus a new-id StockReserved -> no new history rows, timestamps
#      unchanged, no DLQ.
#   C. Start event late: the Worker is stopped and a completion is crafted while
#      the order is Confirmed -> the implied Processing row is written with At
#      clamped to the confirmation time (the crafted ProcessingStartedAt is
#      earlier); the start event then arrives and is a no-op.
#   C2. Implied-path Seq order: 10 orders complete while Confirmed (Worker
#      stopped), and each history, read by Seq, is Confirmed -> Processing
#      (implied) then Processing -> Completed (not implied) -- proving the
#      two-save transaction fixed the insert order (review R9). The Worker's
#      backlog is then drained so case D starts from a clean state (review R10).
#   D. Worker events while PendingStock: the order's StockReserved is held
#      (Inbox INSERT revoked) while the Worker's start and completion arrive ->
#      both are requeued, not dead-lettered, and applied once StockReserved
#      lands; the final history is the full four rows.
#   E. ProcessingFailed is unreachable: no order in the database has it, and a
#      source scan finds no TransitionTo(OrderState.ProcessingFailed) outside
#      the enum; the enum still declares it.
#   F. Poison start event (empty ids) -> OrderProcessingStarted.dlq after one
#      attempt, with no effect.
#
# End state: every main and retry queue empty, every DLQ empty except the one
# deliberate F poison in OrderProcessingStarted.dlq, and one Redis deduction per
# order (SCARD = orders placed, stock = initial - orders).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 41     # number of Check calls in the try block (a truncated run must fail)
$mq = "verify-pr-mq"; $amqp = 5695; $mgmt = 15695; $redis = "verify-pr-redis"; $redisPort = 6402
$orderPort = 5141; $invPort = 5142; $workerPort = 5143
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
$p = "pr-$runId"                     # warmed product, used by every real order
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
    $log = Join-Path $env:TEMP "verify-pr-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "pr-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
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
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5141-5143" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-pr-definitions.json"; $conf = Join-Path $env:TEMP "verify-pr-rabbitmq.conf"
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

    # ======================================================== A. normal path
    # Pre-state: all three services running, every queue and DLQ empty, the product warmed.
    Write-Output "== A. Normal path (3 real orders)"
    $aOrders = @()
    for ($i = 0; $i -lt 3; $i++) {
        $id = Post-Order $p ("pr-a-" + $i + "-" + [guid]::NewGuid())
        if ($id) { $aOrders += $id }
    }
    Check "A: 3 orders accepted through the API" ($aOrders.Count -eq 3) "orders=$($aOrders.Count)"
    $aDone = Wait-Until { (AllCompleted $aOrders) } 90
    Check "A: every order ends Completed" $aDone (($aOrders | ForEach-Object { "$_=$(State $_)" }) -join ",")

    $aProgOk = $true; $aIdOk = $true; $aAtOk = $true; $aApiOk = $true
    $aProgDetail = @(); $aIdDetail = @(); $aAtDetail = @(); $aApiDetail = @()
    foreach ($id in $aOrders) {
        $rows = HistoryRows $id
        $derived = DeriveStartMessageId $id
        $expected = @("-|PendingStock", "PendingStock|Confirmed", "Confirmed|Processing", "Processing|Completed")
        # exact four transitions in Seq order; Implied is true only on the
        # Processing row (index 2), which is the path discriminator.
        if ($rows.Count -ne 4) { $aProgOk = $false }
        for ($i = 0; $i -lt [Math]::Min($rows.Count, 4); $i++) {
            $cells = $rows[$i].Split('|')
            if (($cells[0] + "|" + $cells[1]) -ne $expected[$i]) { $aProgOk = $false }
            if ($i -ne 2 -and $cells[3] -ne "false") { $aProgOk = $false }
        }
        $aProgDetail += "$id=$($rows.Count)"
        # MessageId rule for the path taken; the completion row is always OrderId.
        $path = "?"; $idDetail = ""
        if ($rows.Count -eq 4) {
            $proc = $rows[2].Split('|'); $done = $rows[3].Split('|')
            if ($done[2] -ne $id) { $aIdOk = $false }
            if ($proc[3] -eq "false") {
                $path = "direct"
                if ($proc[2] -ne $derived -or $proc[2] -eq $id) { $aIdOk = $false }
                $idDetail = "start=$($proc[2])"
            } elseif ($proc[3] -eq "true") {
                $path = "implied"
                if ($proc[2] -ne $id) { $aIdOk = $false }
                # the derived start id later landed as a no-op Inbox row
                if ((OrdInbox $derived) -ne 1) { $aIdOk = $false }
                $idDetail = "proc=$($proc[2]) inboxDerived=$(OrdInbox $derived)"
            } else {
                $path = "bad-implied"; $aIdOk = $false; $aProgOk = $false
                $idDetail = "procImplied=$($proc[3])"
            }
        } else { $aIdOk = $false; $idDetail = "rows=$($rows.Count)" }
        $aIdDetail += "$id=$path $idDetail"
        # At non-decreasing
        $ats = @($rows | ForEach-Object { $_.Split('|')[4] })
        for ($i = 1; $i -lt $ats.Count; $i++) { if ($ats[$i] -lt $ats[$i-1]) { $aAtOk = $false } }
        $aAtDetail += ($ats -join " -> ")
        # API history matches the DB progression and implied flags (both Seq-ordered)
        $api = ApiHistory $id
        if ($api.Count -ne 4) { $aApiOk = $false; $aApiDetail += "$id=api-$($api.Count)"; continue }
        for ($i = 0; $i -lt 4; $i++) {
            $fr = if ($null -eq $api[$i].from) { "-" } else { "$($api[$i].from)" }
            $to = "$($api[$i].to)"
            if (($fr + "|" + $to) -ne $expected[$i]) { $aApiOk = $false }
            $dbImplied = $rows[$i].Split('|')[3]
            if (("$($api[$i].implied)").ToLower() -ne $dbImplied) { $aApiOk = $false }
        }
        $aApiDetail += "$id=api-ok"
    }
    Check "A: each order's history is the four transitions in Seq order, Implied true only on the Processing row" $aProgOk ($aProgDetail -join ",")
    Check "A: the MessageId rule for each path taken (direct: derived; implied: OrderId + no-op start Inbox)" $aIdOk ($aIdDetail -join ",")
    Check "A: history At values are non-decreasing" $aAtOk ($aAtDetail -join ",")
    Check "A: the API history array matches the database history (Seq order, implied flags)" $aApiOk ($aApiDetail -join ",")
    Check "A: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== A2. deterministic direct path
    # Pre-state: Worker running from A, no pending events. Stops the Worker, orders
    # to Confirmed, then restarts it so the start event applies directly.
    Write-Output "== A2. Deterministic direct path (Worker stopped until Confirmed)"
    Stop-Svc "FlashSale.ProcessWorker"
    $directOrder = Post-Order $p ("pr-direct-" + [guid]::NewGuid())
    $directConfirmed = Wait-Until { (State $directOrder) -eq "Confirmed" } 60
    Check "A2: the order is Confirmed before the Worker starts (Worker stopped)" ($directOrder -ne "" -and $directConfirmed) "order=$directOrder state=$(State $directOrder)"
    Start-Svc "FlashSale.ProcessWorker" "direct"
    $directDone = Wait-Until { (State $directOrder) -eq "Completed" } 60
    Check "A2: the order ends Completed" $directDone "state=$(State $directOrder)"
    $directRows = HistoryRows $directOrder
    $directDerived = DeriveStartMessageId $directOrder
    $directOk = ($directRows.Count -eq 4)
    if ($directRows.Count -eq 4) {
        $directProc = $directRows[2].Split('|')
        $directOk = ($directProc[0] -eq "Confirmed") -and ($directProc[1] -eq "Processing") -and ($directProc[2] -eq $directDerived) -and ($directProc[3] -eq "false")
    }
    Check "A2: the Processing row is NOT implied and carries the derived MessageId" $directOk "proc=$(if ($directRows.Count -eq 4) { $directRows[2] } else { 'none' })"
    Check "A2: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== B. duplicates
    # Pre-state: Worker running (restarted in A2), all A/A2 orders Completed, no
    # pending events. Republishes against A's first order only.
    Write-Output "== B. Duplicates (same ids, plus a new-id StockReserved)"
    $bOrder = $aOrders[0]
    $bDerived = DeriveStartMessageId $bOrder
    $bCompletedBefore = Ts $bOrder "CompletedAt"
    $bDecidedBefore = Ts $bOrder "ConfirmedOrRejectedAt"
    $bHistoryBefore = HistoryCount $bOrder
    $bStartMsg = OrderProcessingStartedPayload $bOrder $bDerived $cStartedAt
    $bDoneMsg = OrderProcessedPayload $bOrder $cStartedAt
    Publish "OrderProcessingStarted" $bStartMsg
    Publish "OrderProcessed" $bDoneMsg
    Publish "StockReserved" (StockReservedPayload $bOrder ([guid]::NewGuid()) $p)
    Start-Sleep 4
    Check "B: republishing the start and completion (same ids) and a new-id StockReserved adds no history rows" ((HistoryCount $bOrder) -eq $bHistoryBefore) "history=$($bHistoryBefore)->$(HistoryCount $bOrder)"
    Check "B: state and timestamps unchanged" ((State $bOrder) -eq "Completed" -and (Ts $bOrder "CompletedAt") -eq $bCompletedBefore -and (Ts $bOrder "ConfirmedOrRejectedAt") -eq $bDecidedBefore) "state=$(State $bOrder) decided=$bDecidedBefore completed=$bCompletedBefore"
    Check "B: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== C. start event late
    # Pre-state: Worker running, no pending events. Stops the Worker, then crafts
    # a completion for a Confirmed order (the started event has not arrived).
    Write-Output "== C. Start event late (completion while Confirmed)"
    Stop-Svc "FlashSale.ProcessWorker"
    $cOrder = Post-Order $p ("pr-c-" + [guid]::NewGuid())
    $cConfirmed = Wait-Until { (State $cOrder) -eq "Confirmed" } 60
    Check "C: the order is Confirmed before the completion arrives (Worker stopped)" ($cConfirmed -and $cOrder -ne "") "order=$cOrder state=$(State $cOrder)"
    Publish "OrderProcessed" (OrderProcessedPayload $cOrder $cStartedAt)
    $cDone = Wait-Until { (State $cOrder) -eq "Completed" } 30
    Check "C: the completion while Confirmed applied the implied path (order Completed)" $cDone "state=$(State $cOrder)"
    $cImplied = @(HistoryRows $cOrder | Where-Object { ($_.Split('|')[0] -eq "Confirmed") -and ($_.Split('|')[1] -eq "Processing") })
    $cDecided = Ts $cOrder "ConfirmedOrRejectedAt"
    $cImpliedOk = ($cImplied.Count -eq 1) -and ($cImplied[0].Split('|')[3] -eq "true") -and ($cImplied[0].Split('|')[4] -eq $cDecided)
    Check "C: the implied Processing row is clamped to the confirmation time (At = ConfirmedOrRejectedAt, not the earlier crafted start)" $cImpliedOk "implied=$(if ($cImplied) { $cImplied[0] } else { 'none' }) decided=$cDecided"
    $cHistoryBeforeStart = HistoryCount $cOrder
    $cDerived = DeriveStartMessageId $cOrder
    Publish "OrderProcessingStarted" (OrderProcessingStartedPayload $cOrder $cDerived $cStartedAt)
    Start-Sleep 3
    Check "C: the late start event is a no-op (no new history row, order stays Completed)" ((HistoryCount $cOrder) -eq $cHistoryBeforeStart -and (State $cOrder) -eq "Completed") "history=$($cHistoryBeforeStart)->$(HistoryCount $cOrder) state=$(State $cOrder)"
    Check "C: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== C2. implied-path Seq order (10 orders)
    # Pre-state: Worker still STOPPED from C; C's order is Completed and its late
    # start event was a no-op. 10 new orders complete while Confirmed; their
    # StockReserved copies queue in ProcessWorker.StockReserved until drained below.
    Write-Output "== C2. Implied-path Seq order (10 orders)"
    # The Worker is still stopped from case C, so every completion applies the
    # implied path: the Processing row and the Completed row are saved together.
    # By Seq the Processing row (implied) must precede the Completed row -- this
    # proves the two-save transaction fixed the insert order (review R9). Ten
    # orders make a random-key misorder statistically visible.
    $c2Orders = @()
    for ($i = 0; $i -lt 10; $i++) {
        $id = Post-Order $p ("pr-c2-" + $i + "-" + [guid]::NewGuid())
        if ($id) { $c2Orders += $id }
    }
    Check "C2: 10 orders accepted" ($c2Orders.Count -eq 10) "orders=$($c2Orders.Count)"
    $c2Confirmed = Wait-Until { @($c2Orders | Where-Object { (State $_) -ne "Confirmed" }).Count -eq 0 } 60
    Check "C2: all 10 orders are Confirmed before the completions arrive (Worker stopped)" $c2Confirmed (($c2Orders | ForEach-Object { "$_=$(State $_)" }) -join ",")
    foreach ($id in $c2Orders) { Publish "OrderProcessed" (OrderProcessedPayload $id $cStartedAt) }
    $c2Done = Wait-Until { @($c2Orders | Where-Object { (State $_) -ne "Completed" }).Count -eq 0 } 60
    Check "C2: all 10 orders end Completed" $c2Done (($c2Orders | ForEach-Object { "$_=$(State $_)" }) -join ",")
    $c2SeqOk = $true; $c2SeqDetail = @()
    foreach ($id in $c2Orders) {
        $rows = HistoryRows $id
        if ($rows.Count -eq 4) {
            $pCells = $rows[2].Split('|'); $dCells = $rows[3].Split('|')
            $procOk = ($pCells[0] -eq "Confirmed") -and ($pCells[1] -eq "Processing") -and ($pCells[3] -eq "true")
            $doneOk = ($dCells[0] -eq "Processing") -and ($dCells[1] -eq "Completed") -and ($dCells[3] -eq "false")
            if (-not ($procOk -and $doneOk)) { $c2SeqOk = $false }
            $c2SeqDetail += "$id=proc($($pCells[0])>$($pCells[1]),implied=$($pCells[3])) done($($dCells[0])>$($dCells[1]),implied=$($dCells[3]))"
        } else { $c2SeqOk = $false; $c2SeqDetail += "$id=rows=$($rows.Count)" }
    }
    Check "C2: by Seq each history is Confirmed->Processing (implied) then Processing->Completed (not implied)" $c2SeqOk ($c2SeqDetail -join ",")
    # Drain the Worker backlog before case D (review R10). The 10 C2 orders'
    # StockReserved have queued in ProcessWorker.StockReserved while the Worker
    # was stopped. Start the Worker, let it consume them (publishing start +
    # completion events that Order Service records as no-ops while the Inbox
    # grant is still intact), and wait until the queue is empty and every C2
    # order's derived start MessageId has its no-op Inbox row.
    Start-Svc "FlashSale.ProcessWorker" "c2"
    $c2WorkerDrained = Wait-Until { (QueueCount "ProcessWorker.StockReserved") -eq 0 } 60
    $c2NoopInbox = Wait-Until { @($c2Orders | Where-Object { (OrdInbox (DeriveStartMessageId $_)) -ne 1 }).Count -eq 0 } 60
    $c2NoopCount = @($c2Orders | Where-Object { (OrdInbox (DeriveStartMessageId $_)) -eq 1 }).Count
    Check "C2: the Worker backlog drained; every late start event is a no-op" ($c2WorkerDrained -and $c2NoopInbox) "workerQ=$(QueueCount 'ProcessWorker.StockReserved') noopInbox=$c2NoopCount/$($c2Orders.Count)"

    # ======================================================== D. worker events while PendingStock
    # Pre-state: the Worker is already running (drained in C2) and every Worker
    # and Order Service queue/DLQ is empty, so D's own events are processed
    # immediately -- no C2 backlog sits in front of them (review R10).
    Write-Output "== D. Worker events while PendingStock (both requeued)"
    # The Inbox INSERT hold must stay well under the StockReserved consumer's 7 s
    # retry ladder (1 s + 2 s + 4 s); if it is held longer, StockReserved is
    # dead-lettered and the order can never complete. So the grant is restored the
    # moment both requeue lines are seen, and "requeued, not dead-lettered" is
    # proven from the log (requeuing attempt 1/3, and no "routing to DLQ" for this
    # order), never from a rabbitmqctl queue count taken while the hold is in place.
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $dOrder = Post-Order $p ("pr-d-" + [guid]::NewGuid())
    Check "D: an order was accepted" ($dOrder -ne "") "order=$dOrder"
    $dStartQueued = Wait-Until { (Log "FlashSale.OrderService") -match "OrderProcessingStarted .* for order $dOrder arrived before its StockReserved; requeuing attempt 1/3" } 30
    $dDoneQueued = Wait-Until { (Log "FlashSale.OrderService") -match "OrderProcessed $dOrder for order $dOrder arrived before its StockReserved; requeuing attempt 1/3" } 30
    Check "D: the order is still PendingStock while its StockReserved is held" ((State $dOrder) -eq "PendingStock") "state=$(State $dOrder)"
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    Check "D: the start event was requeued, not dead-lettered" ($dStartQueued -and (Log "FlashSale.OrderService") -notmatch "OrderProcessingStarted .* for order $dOrder .* routing to DLQ") "start-requeued=$dStartQueued"
    Check "D: the completion was requeued, not dead-lettered" ($dDoneQueued -and (Log "FlashSale.OrderService") -notmatch "OrderProcessed $dOrder for order $dOrder .* routing to DLQ") "completion-requeued=$dDoneQueued"
    $dDone = Wait-Until { (State $dOrder) -eq "Completed" } 90
    $dRows = HistoryRows $dOrder
    $dFull = ($dDone -and $dRows.Count -eq 4)
    if ($dRows.Count -eq 4) {
        $dFull = $dFull -and ($dRows[0].Split('|')[0] -eq "-") -and ($dRows[1].Split('|')[1] -eq "Confirmed") -and ($dRows[2].Split('|')[1] -eq "Processing") -and ($dRows[3].Split('|')[1] -eq "Completed")
    }
    Check "D: after StockReserved lands the order ends Completed with the full four-row history" $dFull "state=$(State $dOrder) rows=$($dRows.Count)"
    Check "D: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== E. ProcessingFailed unreachable
    # Pre-state: all live cases complete, no pending events; static source checks only.
    Write-Output "== E. ProcessingFailed is unreachable"
    $pfOrders = Int1 "SELECT count(*) FROM order_service.orders WHERE `"State`" = 'ProcessingFailed';"
    Check "E: no order in the database has State=ProcessingFailed" ($pfOrders -eq 0) "rows=$pfOrders"
    $src = (Get-ChildItem (Join-Path $repoRoot "src") -Recurse -Filter *.cs | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
    $pfTransitions = @([regex]::Matches($src, 'TransitionTo\(OrderState\.ProcessingFailed\)')).Count
    Check "E: no production code calls TransitionTo(OrderState.ProcessingFailed)" ($pfTransitions -eq 0) "matches=$pfTransitions"
    $enumText = Get-Content -Raw (Join-Path $repoRoot "src\FlashSale.OrderService\Entities\OrderState.cs")
    Check "E: OrderState still declares ProcessingFailed (declared, not removed)" ($enumText -match 'ProcessingFailed') "declared"

    # ======================================================== F. poison start event
    # Pre-state: clean queues and DLQs; only the deliberate poison below reaches a DLQ.
    Write-Output "== F. Poison start event (empty ids)"
    $fDlqBefore = QueueCount "OrderProcessingStarted.dlq"
    $empty = "00000000-0000-0000-0000-000000000000"
    Publish "OrderProcessingStarted" (OrderProcessingStartedPayload $empty $empty $cStartedAt)
    $fDead = Wait-Until { (QueueCount "OrderProcessingStarted.dlq") -eq ($fDlqBefore + 1) } 30
    Start-Sleep 2
    Check "F: a poison start event (empty ids) is dead-lettered after one attempt" $fDead "dlq=$(QueueCount 'OrderProcessingStarted.dlq') before=$fDlqBefore"
    Check "F: the poison start logged the validation error" ((Log "FlashSale.OrderService") -match "Invalid OrderProcessingStarted message: MessageId is empty")
    Check "F: no Inbox row and no state change for the poison" ((OrdInbox $empty) -eq 0) "inbox=$(OrdInbox $empty)"

    # ======================================================== end state
    Write-Output "== End state"
    $allRun = $allQueues + $retryQueues
    $drained = Wait-Until { @($allRun | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0 } 60
    Check "every main and retry queue is empty" $drained (($allRun | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    $otherDlqs = @($allDlqs | Where-Object { $_ -ne "OrderProcessingStarted.dlq" })
    $dlqOk = (@($otherDlqs | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0) -and ((QueueCount "OrderProcessingStarted.dlq") -eq 1)
    Check "every DLQ is empty except the one deliberate F poison in OrderProcessingStarted.dlq" $dlqOk (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    $totalOrders = 16   # A=3 + A2=1 + C=1 + C2=10 + D=1
    Check "one Redis deduction per order (SCARD = $totalOrders, stock = initial - orders)" (
        (Redis "SCARD", "processed:$p") -eq "$totalOrders" -and (Stock $p) -eq "$($initialStock - $totalOrders)") "scard=$(Redis 'SCARD', "processed:$p") stock=$(Stock $p)"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON inventory_service.processed_messages TO inventory_service_user; GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    foreach ($proj in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $proj }
    docker rm -f $mq $redis *> $null
}
Write-Output ""
if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "The six-state Processing history is applied once per transition, ProcessingFailed is unreachable by design, and no input ever reaches it."
