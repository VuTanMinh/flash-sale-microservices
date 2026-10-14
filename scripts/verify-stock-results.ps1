# ============================================================
# Week 8 TP-W01 (docs/stock-results.md): StockReserved / StockRejected drive the
# correct order status, with the Inbox row and the business change committed
# together, through the real Order Service consumer.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-stock-results.ps1 -Container verify-env-pg -DbPort 55432
#
# Starts its own throwaway RabbitMQ (5684/15684) and Order Service (5116,
# reconciliation off), creates orders through the API, publishes result events
# to the exchange exactly as Inventory Service would, and checks the database.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-sr-mq"; $amqp = 5684; $mgmt = 15684; $port = 5116
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
    $defs = Join-Path $env:TEMP "verify-sr-definitions.json"; $conf = Join-Path $env:TEMP "verify-sr-rabbitmq.conf"
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

    $log = Join-Path $env:TEMP "verify-sr-order-service.log"
    $envs = @{ ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"
               ASPNETCORE_URLS = "http://localhost:$port"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.OrderService") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    if (-not (Wait-Until { $null -ne (Mq Get "/queues/%2F/StockRejected") } 90)) { throw "Order Service did not declare its result queues; see $log" }

    # 1. StockReserved -> Confirmed, Inbox row in the same commit
    $a = New-Order; $ma = [guid]::NewGuid()
    Publish-Result "StockReserved" $a $ma
    $ok = Wait-Until { (State $a).StartsWith("Confirmed|") } 20
    Check "StockReserved -> order Confirmed with ConfirmedOrRejectedAt stamped" ($ok -and -not (State $a).EndsWith("|-")) (State $a)
    Check "StockReserved -> exactly one Inbox row for its MessageId" ((InboxCount $ma) -eq 1)

    # 2. StockRejected -> Rejected
    $b = New-Order; $mb = [guid]::NewGuid()
    Publish-Result "StockRejected" $b $mb
    $ok = Wait-Until { (State $b).StartsWith("Rejected|") } 20
    Check "StockRejected -> order Rejected with ConfirmedOrRejectedAt stamped" ($ok -and -not (State $b).EndsWith("|-")) (State $b)
    Check "StockRejected -> exactly one Inbox row for its MessageId" ((InboxCount $mb) -eq 1)

    # 3. Redelivery of the same message: no second effect
    $before = State $a
    Publish-Result "StockReserved" $a $ma
    Start-Sleep 4
    Check "same StockReserved redelivered: state and timestamp unchanged, still one Inbox row" ((State $a) -eq $before -and (InboxCount $ma) -eq 1) "$before -> $(State $a)"

    # 4. Same result as a NEW message: acknowledged no-op, recorded
    $ma2 = [guid]::NewGuid()
    Publish-Result "StockReserved" $a $ma2
    $ok = Wait-Until { (InboxCount $ma2) -eq 1 } 15
    Check "same result with a new MessageId: recorded in the Inbox, state and timestamp unchanged" ($ok -and (State $a) -eq $before)

    # 5. Conflicting result: dead-lettered, nothing recorded
    $dlqBefore = DlqCount "StockRejected.dlq"
    $mc = [guid]::NewGuid()
    Publish-Result "StockRejected" $a $mc
    $ok = Wait-Until { (DlqCount "StockRejected.dlq") -eq ($dlqBefore + 1) } 20
    Check "StockRejected for a Confirmed order: dead-lettered, order still Confirmed, no Inbox row" ($ok -and (State $a) -eq $before -and (InboxCount $mc) -eq 0)

    # 6. Unknown order: acknowledged, nothing recorded, not dead-lettered
    $mu = [guid]::NewGuid(); $dlqR = DlqCount "StockReserved.dlq"
    Publish-Result "StockReserved" ([guid]::NewGuid()) $mu
    Start-Sleep 4
    Check "result for an unknown order: acknowledged without action (no Inbox row, not dead-lettered)" ((InboxCount $mu) -eq 0 -and (DlqCount "StockReserved.dlq") -eq $dlqR -and (Mq Get "/queues/%2F/StockReserved").messages -eq 0)

    # 7. Every applied transition has exactly one Inbox row, and vice versa (commit together)
    $orders = [int](Sql "SELECT count(*) FROM order_service.orders WHERE `"Id`" IN ('$a','$b') AND `"State`" <> 'PendingStock';")
    $inbox = [int](Sql "SELECT count(*) FROM order_service.processed_messages WHERE `"MessageId`" IN ('$ma','$mb');")
    Check "applied transitions (2) match their Inbox rows (2)" ($orders -eq 2 -and $inbox -eq 2)

    # 8. Commit together, on the real database: make the Inbox insert fail.
    #    The state change must not be saved without its Inbox row.
    #    (Whether the message is then retried or lost is the Week 8
    #    database-exception box, checked by verify-db-exceptions.ps1.)
    $d = New-Order; $md = [guid]::NewGuid()
    Sql "REVOKE INSERT ON order_service.processed_messages FROM order_service_user;" | Out-Null
    Publish-Result "StockReserved" $d $md
    Start-Sleep 3
    Check "Inbox insert refused: order stays PendingStock and no Inbox row (state change rolled back with it)" ((State $d).StartsWith("PendingStock|") -and (InboxCount $md) -eq 0) (State $d)
    Sql "GRANT INSERT ON order_service.processed_messages TO order_service_user;" | Out-Null
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
Write-Host "Stock results drive the order state with Inbox and business change committed together." -ForegroundColor Green
