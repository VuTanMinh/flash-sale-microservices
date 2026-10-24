# ============================================================
# TP-L05 (midterm review, before C4): with several Inventory Service replicas,
# every Outbox row is published exactly once.
#
#   powershell -File .\scripts\verify-replicas.ps1 -Container verify-env-pg -DbPort 55432 [-Replicas 2]
#
# Each replica runs its own OutboxPublisherWorker against the same
# inventory_service.outbox_events table. The publisher claims its batch with
# FOR UPDATE SKIP LOCKED inside a transaction, so replicas take different rows.
# Without the lock every replica read the same oldest rows and published them,
# so the broker received each event once per replica.
#
# Runs -Replicas Inventory Service processes (ports 5180..) on a throwaway
# RabbitMQ (5720/15720) and Redis (6430) against the given PostgreSQL. The broker
# starts with the StockRejected queue (the event's required subscriber) and a
# capture queue bound to the same routing key, so every message the broker
# accepts for StockRejected is also counted in the capture queue.
#
# Cases:
#   A. 400 unpublished StockRejected rows inserted at once while the replicas
#      run: all 400 end Published, the capture queue holds exactly 400 messages,
#      and exactly 400 distinct MessageIds (no event published twice).
#   B. The run is meaningful: every replica started its publisher (log line)
#      and the rows were published within 30 s.
#
# Negative control: run the same script against the previous publisher (rows
# read without a lock); case A must fail with more than 400 messages.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432,
    [int]$Replicas = 2,
    [int]$Rows = 400
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0; $checks = 0
$expectedChecks = 5
$mq = "verify-rp-mq"; $amqp = 5720; $mgmt = 15720; $redis = "verify-rp-redis"; $redisPort = 6430
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"; $capture = "verify-capture.StockRejected"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$logs = @()

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 15 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 8 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function ReadLog([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return "" }
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Stop-Inventory {
    Get-CimInstance Win32_Process -Filter "Name='FlashSale.InventoryService.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Wait-Until { @(Get-CimInstance Win32_Process -Filter "Name='FlashSale.InventoryService.exe'").Count -eq 0 } 20 | Out-Null
}
# rabbitmqctl counts are exact; the management API's are a statistic that lags.
function CaptureCount() {
    $line = @(docker exec $mq rabbitmqctl -q list_queues name messages --no-table-headers 2>$null | Where-Object { ($_ -split "\s+")[0] -eq $capture })
    if ($line.Count -eq 0) { return -1 }
    return [int](($line[0] -split "\s+")[1])
}

$tag = "replicas-" + [guid]::NewGuid().ToString("N")
try {
    Write-Output "== Stack: throwaway RabbitMQ and Redis, $Replicas Inventory replicas"
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
    Stop-Inventory
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-rp-definitions.json"; $conf = Join-Path $env:TEMP "verify-rp-rabbitmq.conf"
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
        queues = @(
            @{ name = "StockRejected"; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} }
            @{ name = $capture; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} }
        )
        bindings = @(
            @{ source = $ex; vhost = "/"; destination = "StockRejected"; destination_type = "queue"; routing_key = "StockRejected"; arguments = @{} }
            @{ source = $ex; vhost = "/"; destination = $capture; destination_type = "queue"; routing_key = "StockRejected"; arguments = @{} }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    # No leftover unpublished rows from another run may be counted.
    Sql "UPDATE inventory_service.outbox_events SET `"Published`" = true, `"PublishedAt`" = now() WHERE NOT `"Published`";" | Out-Null

    for ($i = 0; $i -lt $Replicas; $i++) {
        $port = 5180 + $i
        $envs = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$port"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
        foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
        $log = Join-Path $env:TEMP "verify-rp-inventory-$i.log"
        Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.InventoryService") `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
        foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
        $script:logs += $log
    }
    $up = Wait-Until { @($logs | Where-Object { (ReadLog $_) -match "Consuming" }).Count -eq $Replicas } 120
    if (-not $up) { throw "not every Inventory replica started" }
    Start-Sleep 3

    Write-Output "== A. $Rows unpublished StockRejected rows inserted at once"
    Sql "INSERT INTO inventory_service.outbox_events (`"Id`", `"OrderId`", `"EventType`", `"Payload`", `"Published`", `"CreatedAt`") SELECT gen_random_uuid(), o, 'StockRejected', json_build_object('OrderId', o, 'ProductId', '$tag', 'MessageId', gen_random_uuid(), 'CorrelationId', '$tag')::jsonb, false, (now() at time zone 'utc') FROM (SELECT gen_random_uuid() AS o FROM generate_series(1, $Rows)) s;" | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $allPublished = Wait-Until { [int](Sql "SELECT count(*) FROM inventory_service.outbox_events WHERE `"Payload`"->>'ProductId' = '$tag' AND NOT `"Published`";") -eq 0 } 60
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Start-Sleep 3
    $count = CaptureCount
    $msgs = @(Mq Post "/queues/%2F/$capture/get" @{ count = ($Rows * $Replicas + 50); ackmode = "ack_requeue_false"; encoding = "auto" } | ForEach-Object { $_ })
    $ids = @($msgs | ForEach-Object { ($_.payload | ConvertFrom-Json).MessageId } | Sort-Object -Unique)
    $left = Sql "SELECT count(*) FROM inventory_service.outbox_events WHERE `"Payload`"->>'ProductId' = '$tag' AND NOT `"Published`";"
    Check "A: all $Rows rows end Published" $allPublished "left=$left"
    Check "A: the broker received exactly $Rows StockRejected messages (no row published twice)" ($count -eq $Rows) "capture queue=$count"
    Check "A: exactly $Rows distinct MessageIds in the capture queue" ($ids.Count -eq $Rows -and $msgs.Count -eq $Rows) "messages=$($msgs.Count) distinct=$($ids.Count)"

    Write-Output "== B. The run is meaningful"
    Check "B: all $Replicas replicas started their consumer and publisher" (@($logs | Where-Object { (ReadLog $_) -match "Consuming" }).Count -eq $Replicas) "logs=$($logs -join ',')"
    Check "B: the rows were published within 30 s (measured $secs s)" ($allPublished -and $secs -lt 30)
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Stop-Inventory
    docker rm -f $mq $redis *> $null
    Sql "DELETE FROM inventory_service.outbox_events WHERE `"Payload`"->>'ProductId' = '$tag';" | Out-Null
}
Write-Output ""
if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "With $Replicas Inventory replicas every Outbox row was published exactly once."
