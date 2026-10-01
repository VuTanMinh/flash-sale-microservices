# ============================================================
# Week 6 TP-O02: routed publication (docs/outbox.md "Routed confirmation").
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-publication.ps1 -Container verify-env-pg -DbPort 55432
#
# Needs a migrated throwaway database and a built solution. Starts its own
# throwaway RabbitMQ (5681/15681) and Redis (6391), and its own Order Service
# (5111) and Inventory Service (5112) pointed at them, with reconciliation
# disabled. Cases:
#   A valid route            B required queue missing       C binding removed
#   D broker interruption    E negative confirm (full queue) F return (probe)
#   G StockReserved must reach BOTH required queues (Inventory publisher)
#   H Process Worker: OrderProcessed not lost when its queue is missing
# Removes everything it started. Exits 1 on any failure.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-pub-mq"; $redis = "verify-pub-redis"
$amqp = 5681; $mgmt = 15681; $redisPort = 6391
$orderPort = 5111; $invPort = 5112
$ex = "flashsale.order.exchange"
$started = @()
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$api = "http://localhost:$mgmt/api"

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -
    return (@($out | Where-Object { $_ -ne "" }) -join "`n")
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "$api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 5 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function New-Queue([string]$q, $arguments = @{}) { Mq Put "/queues/%2F/$q" @{ durable = $true; arguments = $arguments } | Out-Null }
function Remove-Queue([string]$q) { Mq Delete "/queues/%2F/$q" | Out-Null }
function Bind([string]$q, [string]$key) { Mq Post "/bindings/%2F/e/$ex/q/$q" @{ routing_key = $key } | Out-Null }
function Unbind([string]$q, [string]$key) { Mq Delete "/bindings/%2F/e/$ex/q/$q/$key" | Out-Null }
function Get-Messages([string]$q) {
    $r = Mq Post "/queues/%2F/$q/get" @{ count = 100; ackmode = "ack_requeue_false"; encoding = "auto" }
    return @($r | ForEach-Object { $_ })   # unroll: PS 5.1 returns a JSON array as one object
}
function Bindings([string]$q) { @(Mq Get "/queues/%2F/$q/bindings" | ForEach-Object { $_ } | Where-Object { $_.source -eq $ex } | ForEach-Object { $_.routing_key }) }
function Start-Service([string]$project, [int]$port, [hashtable]$envs) {
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-pub-$project.log"
    $p = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:started += $p
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep 2
        if ($p.HasExited) { break }
        try { Invoke-WebRequest -UseBasicParsing "http://localhost:$port/" -TimeoutSec 3 -ErrorAction Stop | Out-Null; return $log } catch { if ($_.Exception.Response) { return $log } }
    }
    throw "$project did not start; see $log"
}
function Post-Order([string]$key) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" -Headers @{ "Idempotency-Key" = $key } `
            -Body '{"productId":"flash-product-1","quantity":1}' "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return ($r.Content | ConvertFrom-Json).id
    } catch { return $null }
}
function Order-Published([string]$orderId) { (Sql "SELECT `"Published`" FROM order_service.outbox_events WHERE `"OrderId`" = '$orderId';") -eq "t" }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
# Callers wrap the result in @(): PS 5.1 unrolls a one-element array to a
# PSCustomObject, which has no .Count.
function Messages-For([object[]]$msgs, [string]$orderId) { @($msgs | Where-Object { ($_.payload | ConvertFrom-Json).OrderId -eq $orderId }) }

try {
    # --- throwaway broker (user + exchange only, no queues) and Redis ---
    docker rm -f $mq $redis *> $null
    $defs = Join-Path $env:TEMP "verify-pub-definitions.json"; $conf = Join-Path $env:TEMP "verify-pub-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev"))
    $hash = [Convert]::ToBase64String($salt + $sha)
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(@{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
    } | ConvertTo-Json -Depth 5 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    $orderLog = Start-Service "FlashSale.OrderService" $orderPort @{
        ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"
        ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }

    # A. valid route
    New-Queue "OrderPlaced"; Bind "OrderPlaced" "OrderPlaced"
    $a = Post-Order ("pub-a-" + [guid]::NewGuid())
    $ok = Wait-Until { Order-Published $a }
    $m = @(Messages-For (Get-Messages "OrderPlaced") $a)
    Check "A valid route: row published and exactly one message in OrderPlaced" ($ok -and $m.Count -eq 1) "published $ok, messages $($m.Count)"

    # B. required queue missing -> not published; recovers when the queue appears (unbound)
    Remove-Queue "OrderPlaced"
    $b = Post-Order ("pub-b-" + [guid]::NewGuid())
    Start-Sleep 10
    Check "B queue missing: row stays unpublished" (-not (Order-Published $b))
    Check "B queue missing: publisher logged the failure and keeps retrying" (@(Select-String -Path $orderLog -Pattern "Failed to publish outbox event").Count -ge 1)
    New-Queue "OrderPlaced"   # consumer comes back, deliberately WITHOUT a binding
    $ok = Wait-Until { Order-Published $b }
    $m = @(Messages-For (Get-Messages "OrderPlaced") $b)
    Check "B recovery: once the queue exists the row is published and delivered once" ($ok -and $m.Count -eq 1) "published $ok, messages $($m.Count)"
    Check "B recovery: publisher restored the binding" ((Bindings "OrderPlaced") -contains "OrderPlaced")

    # C. binding removed -> restored, no loss
    Unbind "OrderPlaced" "OrderPlaced"
    $c = Post-Order ("pub-c-" + [guid]::NewGuid())
    $ok = Wait-Until { Order-Published $c }
    $m = @(Messages-For (Get-Messages "OrderPlaced") $c)
    Check "C binding removed: binding restored, row published, delivered once" ($ok -and $m.Count -eq 1 -and (Bindings "OrderPlaced") -contains "OrderPlaced") "published $ok, messages $($m.Count)"

    # D. broker interruption
    docker stop $mq | Out-Null
    $d = Post-Order ("pub-d-" + [guid]::NewGuid())
    Start-Sleep 8
    Check "D broker down: order accepted, row unpublished" ($null -ne $d -and -not (Order-Published $d))
    docker start $mq | Out-Null
    Wait-Until { $null -ne (Mq Get "/overview") } 90 | Out-Null
    $ok = Wait-Until { Order-Published $d } 60
    $m = @(Messages-For (Get-Messages "OrderPlaced") $d)
    Check "D broker back: row published and delivered exactly once" ($ok -and $m.Count -eq 1) "published $ok, messages $($m.Count)"

    # E. negative confirm: full queue with reject-publish
    Remove-Queue "OrderPlaced"
    New-Queue "OrderPlaced" @{ "x-max-length" = 1; "x-overflow" = "reject-publish" }; Bind "OrderPlaced" "OrderPlaced"
    $e1 = Post-Order ("pub-e1-" + [guid]::NewGuid())
    Wait-Until { Order-Published $e1 } | Out-Null
    $e2 = Post-Order ("pub-e2-" + [guid]::NewGuid())
    Start-Sleep 8
    Check "E nack: first fills the queue (published); second is nacked and stays unpublished" ((Order-Published $e1) -and -not (Order-Published $e2))
    Check "E nack: publisher logged the rejected publish" (@(Select-String -Path $orderLog -Pattern "nack|PublishException|Failed to publish outbox event").Count -ge 2)
    Get-Messages "OrderPlaced" | Out-Null   # consume -> space frees up
    $ok = Wait-Until { Order-Published $e2 } 30
    $m = @(Messages-For (Get-Messages "OrderPlaced") $e2)
    Check "E recovery: after space frees up the row is published and delivered once" ($ok -and $m.Count -eq 1) "published $ok, messages $($m.Count)"

    # F. return (unroutable, mandatory) -> PublishException.IsReturn
    $probe = dotnet run --project (Join-Path $repoRoot "tests\BrokerProbe") -- $amqp flashsale flashsale_dev 2>&1 | Out-String
    Check "F return: unroutable mandatory publish raises PublishException(IsReturn=true)" ($LASTEXITCODE -eq 0 -and $probe -match "PASS") $probe.Trim()

    # G. StockReserved must reach BOTH required queues (Inventory Service publisher)
    # Stop Order Service first: its own consumer owns the StockReserved queue
    # and would consume (and correctly ack as "unknown order") the copy this
    # case needs to count.
    foreach ($p in $started) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $started = @()
    Remove-Queue "StockReserved"; Remove-Queue "StockRejected"; Remove-Queue "ProcessWorker.StockReserved"
    New-Queue "StockReserved"; New-Queue "StockRejected"
    $inv = [guid]::NewGuid(); $msgId = [guid]::NewGuid()
    $payload = "{`"OrderId`":`"$inv`",`"ProductId`":`"flash-product-1`",`"MessageId`":`"$msgId`",`"CorrelationId`":`"verify-publication`"}"
    Sql "INSERT INTO inventory_service.outbox_events (`"Id`",`"OrderId`",`"EventType`",`"Payload`",`"Published`",`"CreatedAt`") VALUES ('$([guid]::NewGuid())','$inv','StockReserved','$payload'::jsonb,false,now() at time zone 'utc');" | Out-Null
    $invLog = Start-Service "FlashSale.InventoryService" $invPort @{
        ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"
        ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    $invPublished = { (Sql "SELECT `"Published`" FROM inventory_service.outbox_events WHERE `"OrderId`" = '$inv';") -eq "t" }
    Start-Sleep 10
    Check "G only StockReserved queue exists: row stays unpublished (Process Worker queue missing)" (-not (& $invPublished))
    Check "G nothing was delivered to the existing StockReserved queue meanwhile" (@(Messages-For (Get-Messages "StockReserved") $inv).Count -eq 0)
    New-Queue "ProcessWorker.StockReserved"
    $ok = Wait-Until $invPublished 30
    $m1 = @(Messages-For (Get-Messages "StockReserved") $inv)
    $m2 = @(Messages-For (Get-Messages "ProcessWorker.StockReserved") $inv)
    Check "G both queues present: published once, one copy in each required queue" ($ok -and $m1.Count -eq 1 -and $m2.Count -eq 1) "published $ok, StockReserved $($m1.Count), ProcessWorker $($m2.Count)"

    # H. Process Worker: OrderProcessed must not be lost when its queue is missing
    foreach ($p in $started) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $started = @()
    Remove-Queue "ProcessWorker.StockReserved"; Remove-Queue "OrderProcessed"; Remove-Queue "StockReserved"
    $workerLog = Start-Service "FlashSale.ProcessWorker" 5113 @{
        Urls = "http://localhost:5113"; RabbitMQ__Connections__Default__Port = "$amqp" }
    Wait-Until { $null -ne (Mq Get "/queues/%2F/ProcessWorker.StockReserved") } 30 | Out-Null
    $h1 = [guid]::NewGuid()
    $sr = "{`"OrderId`":`"$h1`",`"ProductId`":`"flash-product-1`",`"MessageId`":`"$([guid]::NewGuid())`",`"CorrelationId`":`"verify-publication`"}"
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = "StockReserved"; content_type = "application/json" }; routing_key = "StockReserved"; payload = $sr; payload_encoding = "string" } | Out-Null
    $dlq = Wait-Until { (Mq Get "/queues/%2F/ProcessWorker.StockReserved.dlq").messages -ge 1 } 60
    Check "H OrderProcessed queue missing: worker does not lose the event -- StockReserved is retried, then dead-lettered" $dlq
    Check "H worker logged the failed OrderProcessed publish" (@(Select-String -Path $workerLog -Pattern "Failed to process order").Count -ge 1)
    New-Queue "OrderProcessed"
    $h2 = [guid]::NewGuid()
    $sr2 = "{`"OrderId`":`"$h2`",`"ProductId`":`"flash-product-1`",`"MessageId`":`"$([guid]::NewGuid())`",`"CorrelationId`":`"verify-publication`"}"
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = "StockReserved"; content_type = "application/json" }; routing_key = "StockReserved"; payload = $sr2; payload_encoding = "string" } | Out-Null
    $got = Wait-Until { (Mq Get "/queues/%2F/OrderProcessed").messages -ge 1 } 30
    $mh = @(Messages-For (Get-Messages "OrderProcessed") "$h2")
    Check "H OrderProcessed queue present: exactly one OrderProcessed with MessageId = OrderId" ($got -and $mh.Count -eq 1 -and (($mh[0].payload | ConvertFrom-Json).MessageId -eq "$h2")) "messages $($mh.Count)"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    foreach ($p in $started) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    docker rm -f $mq $redis *> $null
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Routed publication verified: nothing is marked published without reaching every required queue." -ForegroundColor Green
