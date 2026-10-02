# ============================================================
# Week 7 TP-I03 (docs/design-decisions.md section 4, docs/inventory.md):
# PostgreSQL fails AFTER Redis reserved a unit; a retry must rebuild the
# StockReserved result without a second deduction.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-cross-store.ps1 -Container verify-env-pg -DbPort 55432
#
# The fault: INSERT on inventory_service.outbox_events is revoked from
# inventory_service_user, so the Outbox write fails after reserve.lua ran.
#   Case 1 (short outage): privilege restored inside the consumer's retry
#           window (1 s + 2 s + 4 s) -> the retry writes the result.
#   Case 2 (long outage):  retries exhausted -> message dead-lettered, NOT
#           acked as done; after the fault is removed, re-delivering the
#           dead-lettered message rebuilds the result.
# Uses its own throwaway Redis and RabbitMQ and its own Inventory Service.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$redis = "verify-xs-redis"; $redisPort = 6394
$mq = "verify-xs-mq"; $amqp = 5683; $mgmt = 15683; $invPort = 5115
$ex = "flashsale.order.exchange"
$svc = $null
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -
    return (@($out | Where-Object { $_ -ne "" }) -join "`n")
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 5 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis([string[]]$a) { (docker exec $redis redis-cli @a 2>&1 | Out-String).Trim() }
function Publish-OrderPlaced([string]$payload) {
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = "OrderPlaced"; content_type = "application/json" }; routing_key = "OrderPlaced"; payload = $payload; payload_encoding = "string" } | Out-Null
}
function Result([string]$orderId) { Sql "SELECT `"EventType`" FROM inventory_service.outbox_events WHERE `"OrderId`" = '$orderId';" }
function Revoke { Sql "REVOKE INSERT ON inventory_service.outbox_events FROM inventory_service_user;" | Out-Null }
function Grant { Sql "GRANT INSERT ON inventory_service.outbox_events TO inventory_service_user;" | Out-Null }

try {
    docker rm -f $redis $mq *> $null
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    Start-Sleep 3
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ "xs-product" = 5 } *> $null
    Check "setup: xs-product warmed up with 5 units" ((Redis @("GET", "inventory:xs-product")) -eq "5")

    $defs = Join-Path $env:TEMP "verify-xs-definitions.json"; $conf = Join-Path $env:TEMP "verify-xs-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $hash = [Convert]::ToBase64String($salt + [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev")))
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(@{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
        queues = @("StockReserved", "ProcessWorker.StockReserved", "StockRejected" | ForEach-Object { @{ name = $_; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} } })
    } | ConvertTo-Json -Depth 5 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    $log = Join-Path $env:TEMP "verify-xs-inventory-service.log"
    $envs = @{ ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"
               ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.InventoryService") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    if (-not (Wait-Until { $null -ne (Mq Get "/queues/%2F/OrderPlaced") } 90)) { throw "Inventory Service did not declare its OrderPlaced queue; see $log" }

    # ---- Case 1: short outage, recovered inside the retry window ----
    $o1 = [guid]::NewGuid(); $m1 = [guid]::NewGuid()
    Revoke
    Publish-OrderPlaced "{`"OrderId`":`"$o1`",`"ProductId`":`"xs-product`",`"Quantity`":1,`"MessageId`":`"$m1`",`"CorrelationId`":`"verify-cross-store-1`"}"
    Start-Sleep 2
    Check "case 1: during the fault Redis already reserved (stock 4, order recorded) but no result row exists" ((Redis @("GET", "inventory:xs-product")) -eq "4" -and (Redis @("SISMEMBER", "processed:xs-product", "$o1")) -eq "1" -and (Result $o1) -eq "")
    Grant
    $ok = Wait-Until { (Result $o1) -eq "StockReserved" } 20
    Check "case 1: after the fault clears, the retry writes StockReserved" $ok "result '$(Result $o1)'"
    Check "case 1: no second deduction (stock still 4, one reservation)" ((Redis @("GET", "inventory:xs-product")) -eq "4" -and (Redis @("SCARD", "processed:xs-product")) -eq "1")
    Check "case 1: Inbox row recorded for the message" ((Sql "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$m1';") -eq "1")
    Check "case 1: the retry saw DUPLICATE from Redis (no re-reservation)" (@(Select-String -Path $log -Pattern "OrderPlaced $o1 for product xs-product -> Duplicate").Count -ge 1)

    # ---- Case 2: long outage, retries exhausted ----
    $o2 = [guid]::NewGuid(); $m2 = [guid]::NewGuid()
    Revoke
    Publish-OrderPlaced "{`"OrderId`":`"$o2`",`"ProductId`":`"xs-product`",`"Quantity`":1,`"MessageId`":`"$m2`",`"CorrelationId`":`"verify-cross-store-2`"}"
    $dead = Wait-Until { (Mq Get "/queues/%2F/OrderPlaced.dlq").messages -ge 1 } 40
    Check "case 2: after retries are exhausted the message is dead-lettered, not acked as done" $dead
    Check "case 2: Redis deducted exactly once (stock 3) and still no result row" ((Redis @("GET", "inventory:xs-product")) -eq "3" -and (Result $o2) -eq "")
    Check "case 2: no Inbox row was written for the failed message" ((Sql "SELECT count(*) FROM inventory_service.processed_messages WHERE `"MessageId`" = '$m2';") -eq "0")
    Grant
    $dl = Mq Post "/queues/%2F/OrderPlaced.dlq/get" @{ count = 10; ackmode = "ack_requeue_false"; encoding = "auto" }
    $dl = @($dl | ForEach-Object { $_ })
    foreach ($msg in $dl) { Publish-OrderPlaced $msg.payload }   # operator replays the dead letter
    $ok = Wait-Until { (Result $o2) -eq "StockReserved" } 20
    Check "case 2: replaying the dead-lettered message rebuilds StockReserved" $ok "result '$(Result $o2)'"
    Check "case 2: no second deduction (stock still 3, two reservations in total)" ((Redis @("GET", "inventory:xs-product")) -eq "3" -and (Redis @("SCARD", "processed:xs-product")) -eq "2")
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Grant
    if ($svc) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
    }
    docker rm -f $redis $mq *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Cross-store failure verified: one deduction, result rebuilt by retry." -ForegroundColor Green
