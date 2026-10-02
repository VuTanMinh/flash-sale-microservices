# ============================================================
# Week 8 TP-W03 (docs/design-decisions.md section 4): a database error while
# Order Service applies a stock result must be retried and finally
# dead-lettered -- never acknowledged as "already processed" -- and the result
# must be applied once the fault clears.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-db-exceptions.ps1 -Container verify-env-pg -DbPort 55432
#
# Fault: INSERT on order_service.processed_messages revoked from
# order_service_user, so the result's commit fails (not a duplicate).
#   Case 1: privilege restored inside the consumer's retry window.
#   Case 2: retries exhausted -> dead-lettered; dead letter replayed after.
# Own throwaway RabbitMQ (5686/15686) and Order Service (5120, reconciliation off).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-dbx-mq"; $amqp = 5686; $mgmt = 15686; $port = 5120
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
function New-Order {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" -Headers @{ "Idempotency-Key" = "sr-" + [guid]::NewGuid() } `
        -Body '{"productId":"flash-product-1","quantity":1}' "http://localhost:$port/api/orders" -TimeoutSec 15
    return ($r.Content | ConvertFrom-Json).id
}
function Publish-Result([string]$type, [string]$orderId, [string]$messageId) {
    $p = "{`"OrderId`":`"$orderId`",`"ProductId`":`"flash-product-1`",`"MessageId`":`"$messageId`",`"CorrelationId`":`"verify-stock-results`"}"
    Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = $type; content_type = "application/json" }; routing_key = $type; payload = $p; payload_encoding = "string" } | Out-Null
}
function State([string]$orderId) { Sql "SELECT `"State`" || '|' || coalesce(to_char(`"ConfirmedOrRejectedAt`", 'YYYY-MM-DD HH24:MI:SS.US'), '-') FROM order_service.orders WHERE `"Id`" = '$orderId';" }
function InboxCount([string]$messageId) { [int](Sql "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" = '$messageId';") }
function DlqCount([string]$q) { $r = Mq Get "/queues/%2F/$q"; if ($r) { [int]$r.messages } else { -1 } }

try {
    docker rm -f $mq *> $null
    $defs = Join-Path $env:TEMP "verify-dbx-definitions.json"; $conf = Join-Path $env:TEMP "verify-dbx-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $hash = [Convert]::ToBase64String($salt + [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev")))
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(@{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
        queues = @(@{ name = "OrderPlaced"; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} })   # stands in for Inventory Service
    } | ConvertTo-Json -Depth 5 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    $log = Join-Path $env:TEMP "verify-dbx-order-service.log"
    $envs = @{ ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"
               ASPNETCORE_URLS = "http://localhost:$port"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.OrderService") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    if (-not (Wait-Until { $null -ne (Mq Get "/queues/%2F/StockRejected") } 90)) { throw "Order Service did not declare its result queues; see $log" }

    function Revoke { Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null }
    function Grant { Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null }

    # Case 1: short outage
    $a = New-Order; $ma = [guid]::NewGuid()
    Revoke
    Publish-Result "StockReserved" $a $ma
    Start-Sleep 2
    Check "case 1: during the fault the order is still PendingStock with no Inbox row" ((State $a).StartsWith("PendingStock|") -and (InboxCount $ma) -eq 0) (State $a)
    Grant
    $ok = Wait-Until { (State $a).StartsWith("Confirmed|") } 20
    Check "case 1: after the fault clears, the retry applies it: Confirmed with one Inbox row" ($ok -and (InboxCount $ma) -eq 1) (State $a)
    Check "case 1: the consumer logged a retry, not an 'already processed' no-op" ((@(Select-String -Path $log -Pattern "Failed to process StockReserved $ma").Count -ge 1) -and (@(Select-String -Path $log -Pattern "StockReserved $ma for order $a already processed").Count -eq 0))

    # Case 2: long outage
    $b = New-Order; $mb = [guid]::NewGuid()
    $dlqBefore = DlqCount "StockReserved.dlq"
    Revoke
    Publish-Result "StockReserved" $b $mb
    $dead = Wait-Until { (DlqCount "StockReserved.dlq") -eq ($dlqBefore + 1) } 40
    Check "case 2: retries exhausted -> dead-lettered, not acknowledged as done" $dead
    Check "case 2: order still PendingStock, no Inbox row" ((State $b).StartsWith("PendingStock|") -and (InboxCount $mb) -eq 0) (State $b)
    Grant
    $dl = @(Mq Post "/queues/%2F/StockReserved.dlq/get" @{ count = 10; ackmode = "ack_requeue_false"; encoding = "auto" } | ForEach-Object { $_ })
    foreach ($m in $dl) { Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = "StockReserved"; content_type = "application/json" }; routing_key = "StockReserved"; payload = $m.payload; payload_encoding = "string" } | Out-Null }
    $ok = Wait-Until { (State $b).StartsWith("Confirmed|") } 20
    Check "case 2: replaying the dead letter applies it: Confirmed with one Inbox row" ($ok -and (InboxCount $mb) -eq 1) (State $b)

    # A genuine duplicate is still absorbed (only unique violations are duplicates)
    Publish-Result "StockReserved" $b $mb
    Start-Sleep 4
    Check "a genuine redelivery after the fix is still a no-op (one Inbox row, not dead-lettered)" ((InboxCount $mb) -eq 1 -and (DlqCount "StockReserved.dlq") -eq $dlqBefore)
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
    if ($svc) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
    }
    docker rm -f $mq *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Database errors are retried and dead-lettered, never acknowledged as duplicates." -ForegroundColor Green
