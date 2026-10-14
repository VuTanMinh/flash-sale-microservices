# ============================================================
# Week 11 TP-P01 (docs/process-worker.md): the Process Worker's downstream work
# is deterministic (a fixed configured delay, no random business failure), and
# exactly one completion result is applied per order under replay (same identity),
# a duplicate business event (new MessageId), concurrent copies, a graceful
# restart (real Ctrl+C) and a hard crash, and event reordering (completion
# before the stock result; a late stock result after completion).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-worker.ps1 -Container verify-env-pg -DbPort 55432
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5694/15694) and Redis (6401) against the given PostgreSQL container.
# Services run on ports 5138 (Order), 5139 (Inventory) and 5140 (Worker).
#
# Cases:
#   A. Deterministic success: 5 real orders, each Completed, each Worker
#      "processed in {ElapsedMs}ms" at least the configured delay (500ms) and
#      below delay + a 1500ms tolerance, each applied OrderProcessed carrying
#      MessageId = OrderId (one Order Inbox row), no Worker warning/error, no DLQ.
#   B. Replay, same identity: the original StockReserved body republished to the
#      Worker queue -> the Worker attempts it again (counter +1) but Order Service
#      applies nothing new (still one Inbox row, CompletedAt unchanged), no DLQ.
#   C. Duplicate business event, new MessageId: same order id, fresh MessageId,
#      published to the Worker queue -> same expectations as B.
#   D. Concurrent copies: 5 copies of one completed order's StockReserved at once
#      -> still one applied completion, CompletedAt unchanged, no DLQ.
#   E. Restart:
#      E1 graceful: delay 3000ms, 5 orders, a real Ctrl+C (kernel32 AttachConsole +
#         GenerateConsoleCtrlEvent) after the first "Received" line -> the Worker
#         exits by itself, the DLQ is unchanged, "Shutdown during processing" is
#         logged, not every order is already Completed; after restart all 5 end
#         Completed, DLQ still unchanged.
#      E2 crash: the same with Stop-Process -Force -> ends the same way.
#   F. Event reordering (completion before the stock result): the order's
#      StockReserved is held at Order Service (INSERT on its Inbox revoked) while
#      the Worker's completion arrives -> the completion is requeued (detected from
#      the Order log line), not dead-lettered; once the grant is restored the order
#      ends Completed exactly once with ConfirmedOrRejectedAt <= CompletedAt, no DLQ.
#   G. Late stock result after completion: the completed order's StockReserved is
#      republished to Order Service's StockReserved queue -> a no-op (state
#      Completed, timestamps unchanged), no DLQ.
#
# End state: every main and retry queue empty, every DLQ still empty, every order
# Completed with exactly one Redis deduction (SCARD = number of orders placed, and
# stock = initial - orders).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 51     # number of Check calls in the try block (R3: a truncated run must fail)
$mq = "verify-wk-mq"; $amqp = 5694; $mgmt = 15694; $redis = "verify-wk-redis"; $redisPort = 6401
$orderPort = 5138; $invPort = 5139; $workerPort = 5140
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$logs = @{}   # project -> current log file (redirected stdout, or the Worker's logs.json in case E)
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$p = "wk-$runId"                     # warmed product, used by every real order
$initialStock = 40
$elapsedToleranceMs = 1500           # case A: elapsed must be >= delay (500) and < delay + this
$workerExe = Join-Path $repoRoot "src\FlashSale.ProcessWorker\bin\Debug\net10.0\FlashSale.ProcessWorker.exe"
$workerJsonLog = Join-Path $repoRoot "src\FlashSale.ProcessWorker\bin\Debug\net10.0\Logs\logs.json"
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessingStarted.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"
$retryQueues = "OrderProcessingStarted.retry.1", "OrderProcessingStarted.retry.2", "OrderProcessingStarted.retry.3", "OrderProcessed.retry.1", "OrderProcessed.retry.2", "OrderProcessed.retry.3"

# ------------------------------------------------------------------ helpers
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    # Count BEFORE any output, and write to the output stream (not the host),
    # so a broken console can never turn a failure into a pass (review R2).
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
# statistics, which lag (AGENTS.md Part B / verify-failures.ps1 QueueDepth).
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
    $log = Join-Path $env:TEMP "verify-wk-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function WorkerProcessed() {
    try { $m = (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$workerPort/metrics" -TimeoutSec 5).Content }
    catch { return -1 }
    $line = @($m -split "`r?`n" | Where-Object { $_ -like "flashsale_orders_processed_total*" })[0]
    if (-not $line) { return -1 }
    $parts = @($line -split " ")
    return [int]$parts[$parts.Count - 1]
}
function WorkerElapsed([string]$orderId) {
    $text = Log "FlashSale.ProcessWorker"
    if (-not $text) { return -1 }
    $m = [regex]::Match($text, "Order " + [regex]::Escape($orderId) + " processed in (\d+)ms")
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -1
}
function WorkerWarnErrLines() {
    $text = Log "FlashSale.ProcessWorker"
    if (-not $text) { return 0 }
    return @($text -split "`r?`n" | Where-Object { $_ -match '\[\d{2}:\d{2}:\d{2} (WRN|ERR|FTL)\]' }).Count
}
# Used once, before the own-console Worker start (case E1): clears an inherited
# "ignore Ctrl+C" flag in this process so the Worker does not inherit it.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VerifierConsole {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);
}
"@
# The Worker's own Serilog file sink (case E, own-console start) stores the message
# TEMPLATE (@mt) plus the structured properties, so we match the template text.
function JsonLogText() { return (Log "FlashSale.ProcessWorker") }
function JsonLogCount([string]$needle) {
    $text = JsonLogText
    if (-not $text) { return 0 }
    return @([regex]::Matches($text, [regex]::Escape($needle))).Count
}
function JsonLogLen() {
    if (-not (Test-Path -LiteralPath $workerJsonLog)) { return 0 }
    return (Get-Item -LiteralPath $workerJsonLog).Length
}
function JsonLogTail([long]$offset) {
    if (-not (Test-Path -LiteralPath $workerJsonLog)) { return "" }
    $fs = [IO.File]::Open($workerJsonLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($offset -lt 0) { $offset = 0 }
        if ($offset -gt $fs.Length) { $offset = $fs.Length }
        $fs.Seek($offset, [IO.SeekOrigin]::Begin) | Out-Null
        return (New-Object IO.StreamReader($fs)).ReadToEnd()
    } finally { $fs.Dispose() }
}
function Post-Order([string]$product, [string]$correlationId) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "wk-" + [guid]::NewGuid(); "X-Correlation-Id" = $correlationId } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function Ts([string]$id, [string]$col) { return (Sql "SELECT coalesce(to_char(`"$col`", 'YYYY-MM-DD HH24:MI:SS.US'), '-') FROM order_service.orders WHERE `"Id`" = '$id';") }
function OrdInbox([string]$msg) { if (-not $msg) { return -1 }; return (Int1 "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$msg';") }
function ResultPayload([string]$id) { return (Sql "SELECT `"Payload`"::text FROM inventory_service.outbox_events WHERE `"OrderId`" = '$id' ORDER BY `"CreatedAt`" LIMIT 1;") }
function AllCompleted([string[]]$ids) { foreach ($id in $ids) { if ((State $id) -ne "Completed") { return $false } }; return $true }
function Publish-Queue([string]$queue, [string]$eventType, [string]$payload) {
    Mq Post "/exchanges/%2F/amq.default/publish" @{ properties = @{ type = $eventType; content_type = "application/json" }; routing_key = $queue; payload = $payload; payload_encoding = "string" } | Out-Null
}
function Publish-QueueParallel([string]$queue, [string]$eventType, [string[]]$payloads) {
    $jobs = @()
    foreach ($pl in $payloads) {
        $jobs += Start-Job -ScriptBlock {
            param($Mgmt, $Queue, $Type, $Payload)
            try {
                $body = @{ properties = @{ type = $Type; content_type = "application/json" }; routing_key = $Queue; payload = $Payload; payload_encoding = "string" } | ConvertTo-Json -Depth 5 -Compress
                $bytes = [Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")
                $hdr = @{ Authorization = "Basic " + [Convert]::ToBase64String($bytes) }
                Invoke-RestMethod -Method Post -Headers $hdr -ContentType "application/json" -Body $body -Uri "http://localhost:$Mgmt/api/exchanges/%2F/amq.default/publish" -TimeoutSec 20 | Out-Null
                return "ok"
            } catch { return "fail" }
        } -ArgumentList $mgmt, $queue, $eventType, $pl
    }
    $null = Wait-Job -Job $jobs -Timeout 60
    $done = @($jobs | Receive-Job)
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    return @($done | Where-Object { $_ -eq "ok" }).Count
}
function AllDlqsEmpty() { foreach ($q in $allDlqs) { if ((QueueCount $q) -ne 0) { return $false } }; return $true }

# Start the Worker via `dotnet run` with its stdout redirected (plain-text log).
function Start-Worker([string]$tag, [int]$delayMs) {
    $envs = @{
        "Urls" = "http://localhost:$workerPort"
        "RabbitMQ__Connections__Default__Port" = "$amqp"
        "Processing__DelayMilliseconds" = "$delayMs"
    }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-wk-worker-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" `
        -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.ProcessWorker") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs["FlashSale.ProcessWorker"] = $log
    Wait-Until { (Test-Path $log) -and (Log "FlashSale.ProcessWorker") -match "Consuming" } 90 | Out-Null
}
# Start the Worker as its own console process (Start-Process without -NoNewWindow,
# the apphost exe directly so a real Ctrl+C reaches a single process), so a
# graceful Ctrl+C can be sent with AttachConsole + GenerateConsoleCtrlEvent. Its
# log is read from the Serilog file sink (logs.json), matched by template text.
function Start-WorkerOwnConsole([string]$tag, [int]$delayMs) {
    $envs = @{
        "Urls" = "http://localhost:$workerPort"
        "RabbitMQ__Connections__Default__Port" = "$amqp"
        "Processing__DelayMilliseconds" = "$delayMs"
    }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $consumeBefore = JsonLogCount "Consuming StockReserved"
    # A process started from a context that ignores Ctrl+C (Git Bash, a background
    # task) passes that ignore flag on to its children, and the Worker would then
    # never see the Ctrl+C sent below. Clear the flag here so the Worker inherits
    # normal Ctrl+C handling whatever shell launched this script.
    [VerifierConsole]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
    $proc = Start-Process -FilePath $workerExe -WorkingDirectory (Split-Path $workerExe) -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs["FlashSale.ProcessWorker"] = $workerJsonLog
    $script:workerPid = $proc.Id
    Wait-Until { (JsonLogCount "Consuming StockReserved") -gt $consumeBefore } 90 | Out-Null
}
# Send a real Ctrl+C to the Worker's console from a SHORT-LIVED HELPER process.
# Only the helper calls FreeConsole/AttachConsole, so the verifier's own console
# is never detached (review R1). Returns the helper's exit code (0 = success).
function Send-CtrlC([int]$pid2) {
    $helper = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WorkerCtrl {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
}
"@
[WorkerCtrl]::FreeConsole() | Out-Null
$a = [WorkerCtrl]::AttachConsole([uint32]__PID__)
if (-not $a) { exit 2 }
[WorkerCtrl]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
$g = [WorkerCtrl]::GenerateConsoleCtrlEvent(0, 0)
Start-Sleep -Milliseconds 300
if ($g) { exit 0 } else { exit 1 }
'@
    $helper = $helper -replace '__PID__', "$pid2"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-EncodedCommand", $encoded -Wait -PassThru -WindowStyle Hidden
    return $proc.ExitCode
}
function CountCompleted([string[]]$ids) { $n = 0; foreach ($id in $ids) { if ((State $id) -eq "Completed") { $n++ } }; return $n }

# ================================================================== run
try {
    # ---------------------------------------------------------- guards
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; this script needs 5138-5140" }
    }
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-wk-definitions.json"; $conf = Join-Path $env:TEMP "verify-wk-rabbitmq.conf"
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
    Start-Worker "a" 500
    $all = $allQueues + $allDlqs
    $ready = Wait-Until { @($all | Where-Object { -not (QueueExists $_) }).Count -eq 0 } 120
    Check "all three services up; every queue and DLQ declared" $ready (($all | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = $initialStock } -Force *> $null
    Check "warm-up: $p has $initialStock units" ((Stock $p) -eq "$initialStock")

    # ======================================================== A. deterministic success
    Write-Output "== A. Deterministic success (delay 500ms, 5 real orders)"
    $aOrders = @()
    for ($i = 0; $i -lt 5; $i++) {
        $id = Post-Order $p ("wk-a-" + $i + "-" + [guid]::NewGuid())
        if ($id) { $aOrders += $id }
    }
    Check "A: 5 orders accepted through the API" ($aOrders.Count -eq 5) "orders=$($aOrders.Count)"
    $aDone = Wait-Until { (AllCompleted $aOrders) } 90
    Check "A: every order ends Completed" $aDone (($aOrders | ForEach-Object { "$_=$(State $_)" }) -join ",")
    $aElapsedOk = $true; $aElapsedDetail = @()
    $aInboxOk = $true
    foreach ($id in $aOrders) {
        $e = WorkerElapsed $id
        if ($e -lt 500 -or $e -ge (500 + $elapsedToleranceMs)) { $aElapsedOk = $false }
        $aElapsedDetail += "$e"
        if ((OrdInbox $id) -ne 1) { $aInboxOk = $false }
    }
    Check "A: each Worker processed-in time is >= 500ms and < 2000ms" $aElapsedOk ($aElapsedDetail -join ",")
    Check "A: each applied OrderProcessed has MessageId = OrderId (one Order Inbox row per order)" $aInboxOk (($aOrders | ForEach-Object { "$_=$(OrdInbox $_)" }) -join ",")
    Check "A: no Worker warning, error or fatal line" ((WorkerWarnErrLines) -eq 0) "warn/err=$(WorkerWarnErrLines)"
    Check "A: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== B. replay, same identity
    Write-Output "== B. Replay, same identity"
    $bOrder = $aOrders[0]
    $bPayload = ResultPayload $bOrder
    $procBeforeB = WorkerProcessed
    $completedBeforeB = Ts $bOrder "CompletedAt"
    Publish-Queue "ProcessWorker.StockReserved" "StockReserved" $bPayload
    $procAfterB = Wait-Until { (WorkerProcessed) -eq ($procBeforeB + 1) } 40
    Check "B: the Worker processed the replayed message again (attempts counter +1)" $procAfterB "counter=$($procBeforeB)->$(WorkerProcessed)"
    Start-Sleep 2
    Check "B: Order Service applied nothing new (still one Inbox row for MessageId = OrderId)" ((OrdInbox $bOrder) -eq 1) "rows=$(OrdInbox $bOrder)"
    Check "B: state stays Completed and CompletedAt unchanged" ((State $bOrder) -eq "Completed" -and (Ts $bOrder "CompletedAt") -eq $completedBeforeB) "state=$(State $bOrder) completed=$completedBeforeB"
    Check "B: no DLQ" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== C. duplicate business event, new MessageId
    Write-Output "== C. Duplicate business event, new MessageId"
    $cOrder = $aOrders[1]
    $cPayload = ResultPayload $cOrder
    $cObj = $cPayload | ConvertFrom-Json
    $cObj.MessageId = [guid]::NewGuid().ToString()
    $cPayload = $cObj | ConvertTo-Json -Compress
    $procBeforeC = WorkerProcessed
    $completedBeforeC = Ts $cOrder "CompletedAt"
    Publish-Queue "ProcessWorker.StockReserved" "StockReserved" $cPayload
    $procAfterC = Wait-Until { (WorkerProcessed) -eq ($procBeforeC + 1) } 40
    Check "C: the Worker processed the new-identity copy again (attempts counter +1)" $procAfterC "counter=$($procBeforeC)->$(WorkerProcessed)"
    Start-Sleep 2
    Check "C: Order Service applied nothing new (still one Inbox row for MessageId = OrderId)" ((OrdInbox $cOrder) -eq 1) "rows=$(OrdInbox $cOrder)"
    Check "C: state stays Completed and CompletedAt unchanged" ((State $cOrder) -eq "Completed" -and (Ts $cOrder "CompletedAt") -eq $completedBeforeC) "state=$(State $cOrder) completed=$completedBeforeC"
    Check "C: no DLQ" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== D. concurrent copies
    Write-Output "== D. Concurrent copies (5 at once)"
    $dOrder = $aOrders[2]
    $dPayload = ResultPayload $dOrder
    $procBeforeD = WorkerProcessed
    $completedBeforeD = Ts $dOrder "CompletedAt"
    $sent = Publish-QueueParallel "ProcessWorker.StockReserved" "StockReserved" (@($dPayload) * 5)
    Check "D: 5 concurrent copies published" ($sent -eq 5) "published=$sent"
    $procAfterD = Wait-Until { (WorkerProcessed) -ge ($procBeforeD + 5) } 60
    Start-Sleep 2
    Check "D: all 5 copies were attempted by the Worker (attempts counter +5)" $procAfterD "counter=$($procBeforeD)->$(WorkerProcessed)"
    Check "D: still one applied completion (one Inbox row, CompletedAt unchanged, Completed)" ((OrdInbox $dOrder) -eq 1 -and (State $dOrder) -eq "Completed" -and (Ts $dOrder "CompletedAt") -eq $completedBeforeD) "rows=$(OrdInbox $dOrder) state=$(State $dOrder)"
    Check "D: no DLQ" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== E. restart
    Stop-Svc "FlashSale.ProcessWorker"

    Write-Output "== E1. Graceful restart (delay 3000ms, real Ctrl+C)"
    Start-WorkerOwnConsole "e1" 3000
    $recvBefore = JsonLogCount "Received StockReserved"
    $e1Orders = @()
    for ($i = 0; $i -lt 5; $i++) {
        $id = Post-Order $p ("wk-e1-" + $i + "-" + [guid]::NewGuid())
        if ($id) { $e1Orders += $id }
    }
    Check "E1: 5 orders accepted" ($e1Orders.Count -eq 5) "orders=$($e1Orders.Count)"
    $recvSeen = Wait-Until { (JsonLogCount "Received StockReserved") -gt $recvBefore } 60
    Check "E1: the Worker received at least one StockReserved before shutdown" $recvSeen "received=$((JsonLogCount 'Received StockReserved') - $recvBefore)"
    $e1ShutdownOffset = JsonLogLen
    $ctrlExit = Send-CtrlC $script:workerPid
    $gracefulExit = Wait-Until { $null -eq (Get-Process -Id $script:workerPid -ErrorAction SilentlyContinue) } 30
    # Only lines written after the Ctrl+C count: logs.json keeps earlier runs' lines.
    $e1ShutdownTail = JsonLogTail $e1ShutdownOffset
    $e1ShuttingDown = @([regex]::Matches($e1ShutdownTail, [regex]::Escape("Application is shutting down"))).Count
    $e1Returned = @([regex]::Matches($e1ShutdownTail, [regex]::Escape("Shutdown during processing"))).Count
    Check "E1: a real Ctrl+C reached the Worker (helper exit 0 and the Worker logged 'Application is shutting down')" ($ctrlExit -eq 0 -and $e1ShuttingDown -ge 1) "helper-exit=$ctrlExit shuttingDownLines=$e1ShuttingDown"
    Check "E1: the Worker exited by itself after Ctrl+C (no force)" $gracefulExit "exited=$gracefulExit"
    Check "E1: ProcessWorker.StockReserved.dlq is unchanged" ((QueueCount "ProcessWorker.StockReserved.dlq") -eq 0) "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
    Check "E1: the Worker logged 'Shutdown during processing' after the Ctrl+C" ($e1Returned -ge 1) "lines=$e1Returned"
    $e1RoutingToDlq = @([regex]::Matches($e1ShutdownTail, [regex]::Escape("routing to DLQ"))).Count
    $e1ErrFatal = @([regex]::Matches($e1ShutdownTail, '"@l":"(Error|Fatal)"')).Count
    Check "E1: no 'routing to DLQ' and no Error/Fatal level line between the Ctrl+C and exit" ($e1RoutingToDlq -eq 0 -and $e1ErrFatal -eq 0) "routingToDlq=$e1RoutingToDlq errFatal=$e1ErrFatal"
    $e1CompletedAtShutdown = CountCompleted $e1Orders
    $e1Pending = @($e1Orders | Where-Object { (State $_) -ne "Completed" })
    if ($e1CompletedAtShutdown -eq 5) { throw "SETUP ERROR: all 5 E1 orders were already Completed before shutdown; the restart case proved nothing" }
    Check "E1: not every order was already Completed at shutdown (the case is meaningful)" ($e1CompletedAtShutdown -lt 5) "completed=$e1CompletedAtShutdown/5"
    Start-Worker "e1r" 3000
    $e1Done = Wait-Until { (AllCompleted $e1Orders) } 90
    Check "E1: after restart the orders pending at shutdown were redelivered and end Completed" $e1Done (($e1Pending | ForEach-Object { "$_=$(State $_)" }) -join ",")
    Check "E1: after restart each order has exactly one applied completion" (@($e1Orders | Where-Object { (OrdInbox $_) -ne 1 }).Count -eq 0) (($e1Orders | ForEach-Object { "$_=$(OrdInbox $_)" }) -join ",")
    Check "E1: DLQ still unchanged" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    Stop-Svc "FlashSale.ProcessWorker"

    Write-Output "== E2. Hard crash (delay 3000ms, Stop-Process -Force)"
    Start-WorkerOwnConsole "e2" 3000
    $recvBefore2 = JsonLogCount "Received StockReserved"
    $e2Orders = @()
    for ($i = 0; $i -lt 5; $i++) {
        $id = Post-Order $p ("wk-e2-" + $i + "-" + [guid]::NewGuid())
        if ($id) { $e2Orders += $id }
    }
    Check "E2: 5 orders accepted" ($e2Orders.Count -eq 5) "orders=$($e2Orders.Count)"
    $recvSeen2 = Wait-Until { (JsonLogCount "Received StockReserved") -gt $recvBefore2 } 60
    Check "E2: the Worker received at least one StockReserved before the crash" $recvSeen2 "received=$((JsonLogCount 'Received StockReserved') - $recvBefore2)"
    Stop-Process -Id $script:workerPid -Force -ErrorAction SilentlyContinue
    $crashed = Wait-Until { $null -eq (Get-Process -Id $script:workerPid -ErrorAction SilentlyContinue) } 20
    Check "E2: the Worker was force-killed (crash)" $crashed "exited=$crashed"
    Check "E2: ProcessWorker.StockReserved.dlq is unchanged" ((QueueCount "ProcessWorker.StockReserved.dlq") -eq 0) "dlq=$(QueueCount 'ProcessWorker.StockReserved.dlq')"
    $e2CompletedAtCrash = CountCompleted $e2Orders
    if ($e2CompletedAtCrash -eq 5) { throw "SETUP ERROR: all 5 E2 orders were already Completed before the crash; the crash case proved nothing" }
    Check "E2: not every order was already Completed at crash (the case is meaningful)" ($e2CompletedAtCrash -lt 5) "completed=$e2CompletedAtCrash/5"
    Start-Worker "e2r" 3000
    $e2Done = Wait-Until { (AllCompleted $e2Orders) } 90
    Check "E2: after restart all 5 orders end Completed" $e2Done (($e2Orders | ForEach-Object { "$_=$(State $_)" }) -join ",")
    Check "E2: after restart each order has exactly one applied completion" (@($e2Orders | Where-Object { (OrdInbox $_) -ne 1 }).Count -eq 0) (($e2Orders | ForEach-Object { "$_=$(OrdInbox $_)" }) -join ",")
    Check "E2: DLQ still unchanged" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    Stop-Svc "FlashSale.ProcessWorker"

    # ======================================================== F. completion before the stock result
    Write-Output "== F. Event reordering: completion before the stock result"
    Start-Worker "f" 500
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    $fOrder = Post-Order $p ("wk-f-" + [guid]::NewGuid())
    Check "F: an order was accepted" ($fOrder -ne "") "order=$fOrder"
    $queued = Wait-Until { (Log "FlashSale.OrderService") -match "OrderProcessed $fOrder for order $fOrder arrived before its StockReserved" } 30
    $opDlqF = QueueCount "OrderProcessed.dlq"
    Check "F: the early completion was requeued, not dead-lettered (log line present)" $queued "requeued=$queued"
    Check "F: OrderProcessed.dlq is still empty at the requeue" ($opDlqF -eq 0) "dlq=$opDlqF"
    Check "F: the order is still PendingStock and has no completion Inbox row while unapplied" ((State $fOrder) -eq "PendingStock" -and (OrdInbox $fOrder) -eq 0) "state=$(State $fOrder) rows=$(OrdInbox $fOrder)"
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    $fDone = Wait-Until { (State $fOrder) -eq "Completed" } 90
    $confirmedTs = Ts $fOrder "ConfirmedOrRejectedAt"
    $completedTs = Ts $fOrder "CompletedAt"
    Check "F: after the grant is restored the order ends Completed exactly once" ($fDone -and (OrdInbox $fOrder) -eq 1) "state=$(State $fOrder) rows=$(OrdInbox $fOrder)"
    Check "F: ConfirmedOrRejectedAt <= CompletedAt" ($confirmedTs -ne "-" -and $completedTs -ne "-" -and ($confirmedTs -le $completedTs)) "confirmed=$confirmedTs completed=$completedTs"
    Check "F: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    Stop-Svc "FlashSale.ProcessWorker"

    # ======================================================== G. late stock result after completion
    Write-Output "== G. Late stock result after completion"
    $gOrder = $aOrders[3]
    $gPayload = ResultPayload $gOrder
    $gStateBefore = State $gOrder
    $gCompletedBefore = Ts $gOrder "CompletedAt"
    $gDecidedBefore = Ts $gOrder "ConfirmedOrRejectedAt"
    Publish-Queue "StockReserved" "StockReserved" $gPayload
    Start-Sleep 3
    Check "G: the late StockReserved is a no-op (state stays Completed, timestamps unchanged)" (
        (State $gOrder) -eq "Completed" -and (Ts $gOrder "CompletedAt") -eq $gCompletedBefore -and (Ts $gOrder "ConfirmedOrRejectedAt") -eq $gDecidedBefore) "state=$(State $gOrder) decided=$gDecidedBefore completed=$gCompletedBefore"
    Check "G: no DLQ grew" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")

    # ======================================================== end state
    Write-Output "== End state"
    $allRun = $allQueues + $retryQueues
    $drained = Wait-Until { @($allRun | Where-Object { (QueueCount $_) -ne 0 }).Count -eq 0 } 60
    Check "every main and retry queue is empty" $drained (($allRun | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    Check "every DLQ is still empty" (AllDlqsEmpty) (($allDlqs | ForEach-Object { "$_=$(QueueCount $_)" }) -join ",")
    $totalOrders = 16   # A=5 + E1=5 + E2=5 + F=1
    Check "every order Completed with exactly one Redis deduction (SCARD = orders, stock = initial - orders)" (
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
Write-Output "The Worker's downstream work is deterministic and exactly one completion is applied per order under replay, restart and reordering."
