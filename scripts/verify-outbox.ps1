# ============================================================
# Week 6 TP-O01: atomic order/Outbox commit and rollback on PostgreSQL, and a
# stable MessageId across publish retries (docs/outbox.md).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-outbox.ps1 -Container verify-env-pg -DbPort 55432
#
# Needs a migrated throwaway database (verify-environment.ps1 -Mode Fresh -Keep)
# and a built solution. Starts its own Order Service (port 5110) pointed at a
# broker port where nothing listens yet (5680), with reconciliation disabled,
# then starts a throwaway RabbitMQ on that port whose exchange, capture queue
# and binding are loaded at boot. Removes everything it started. Exits 1 on
# any failure.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432,
    [int]$ServicePort = 5110,
    [int]$BrokerPort = 5680,
    [int]$BrokerMgmtPort = 15680
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-outbox-mq"
$svc = $null
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -
    return (@($out | Where-Object { $_ -ne "" }) -join "`n")
}
function Post([string]$key) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" -Headers @{ "Idempotency-Key" = $key } `
            -Body '{"productId":"flash-product-1","quantity":1}' "http://localhost:$ServicePort/api/orders" -TimeoutSec 15
        return [int]$r.StatusCode
    } catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return -1 }
}
function OutboxFor([string]$key) {
    Sql "SELECT e.`"Published`" || '|' || (e.`"Payload`"::json->>'MessageId') || '|' || e.`"Payload`"::text FROM order_service.outbox_events e JOIN order_service.orders o ON o.`"Id`" = e.`"OrderId`" WHERE o.`"IdempotencyKey`" = '$key';"
}

try {
    # --- Order Service with an unreachable broker and no reconciliation ---
    docker rm -f $mq *> $null
    $log = Join-Path $env:TEMP "verify-outbox-order-service.log"
    $env:ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"
    $env:ASPNETCORE_URLS = "http://localhost:$ServicePort"
    $env:RabbitMQ__Connections__Default__Port = "$BrokerPort"
    $env:Reconciliation__StuckTimeoutSeconds = "3600"
    $svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" `
        -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.OrderService") -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($v in "ConnectionStrings__Default", "ASPNETCORE_URLS", "RabbitMQ__Connections__Default__Port", "Reconciliation__StuckTimeoutSeconds") { Set-Item "Env:$v" -Value $null }
    $up = $false
    for ($i = 0; $i -lt 60 -and -not $up -and -not $svc.HasExited; $i++) {
        Start-Sleep 2
        try { Invoke-WebRequest -UseBasicParsing "http://localhost:$ServicePort/api/orders/$([guid]::NewGuid())" -TimeoutSec 3 -ErrorAction Stop | Out-Null; $up = $true } catch { if ($_.Exception.Response) { $up = $true } }
    }
    if (-not $up) { throw "Order Service did not start; see $log" }

    # --- 1. Atomic commit ---
    $k1 = "outbox-commit-" + [guid]::NewGuid()
    $code = Post $k1
    $row = OutboxFor $k1
    $orders = [int](Sql "SELECT count(*) FROM order_service.orders WHERE `"IdempotencyKey`" = '$k1';")
    Check "commit: 201, exactly one order and one unpublished OrderPlaced Outbox row" ($code -eq 201 -and $orders -eq 1 -and @($row -split "`n").Count -eq 1 -and $row.StartsWith("false|")) "HTTP $code, orders $orders, outbox '$row'"
    $messageId = ($row -split '\|')[1]
    $orderId = Sql "SELECT `"Id`" FROM order_service.orders WHERE `"IdempotencyKey`" = '$k1';"
    Check "commit: Outbox payload names this order and carries a MessageId" ($row.Contains($orderId) -and $messageId -match '^[0-9a-f-]{36}$')

    # --- 2. Rollback: make the Outbox insert fail on the real database ---
    Sql "REVOKE INSERT ON order_service.outbox_events FROM order_service_user;" | Out-Null
    $k2 = "outbox-rollback-" + [guid]::NewGuid()
    $code2 = Post $k2
    Sql "GRANT INSERT ON order_service.outbox_events TO order_service_user;" | Out-Null
    $orders2 = [int](Sql "SELECT count(*) FROM order_service.orders WHERE `"IdempotencyKey`" = '$k2';")
    Check "rollback: Outbox insert refused -> request fails (5xx) and NO order row exists" ($code2 -ge 500 -and $orders2 -eq 0) "HTTP $code2, orders $orders2"
    $code3 = Post $k2
    Check "rollback: after the fault is removed the same key creates the order normally (201)" ($code3 -eq 201)

    # --- 3. Stable MessageId across retries while the broker is down ---
    Start-Sleep 10
    $failedAttempts = @(Select-String -Path $log -Pattern "Failed to publish outbox event").Count
    $rowDuring = OutboxFor $k1
    Check "retries: publisher logged failed attempts while the broker was down ($failedAttempts)" ($failedAttempts -ge 2)
    Check "retries: row still unpublished and payload unchanged" ($rowDuring -eq $row)

    # Broker comes up with exchange + capture queue + binding already defined.
    # Loading definitions at boot replaces the default user, so the test user
    # (local development credentials, password flashsale_dev) is defined here
    # with RabbitMQ's salted SHA-256 hash.
    $defs = Join-Path $env:TEMP "verify-outbox-definitions.json"
    $conf = Join-Path $env:TEMP "verify-outbox-rabbitmq.conf"
    @'
{"users":[{"name":"flashsale","password_hash":"VS94RV3AoVAtElF5/RZHdK6NaL1ppb4qeumsQRTi2oglXvNE","hashing_algorithm":"rabbit_password_hashing_sha256","tags":["administrator"]}],
 "permissions":[{"user":"flashsale","vhost":"/","configure":".*","write":".*","read":".*"}],
 "vhosts":[{"name":"/"}],
 "exchanges":[{"name":"flashsale.order.exchange","vhost":"/","type":"direct","durable":true,"auto_delete":false,"internal":false,"arguments":{}}],
 "queues":[{"name":"OrderPlaced","vhost":"/","durable":true,"auto_delete":false,"arguments":{}}],
 "bindings":[{"source":"flashsale.order.exchange","vhost":"/","destination":"OrderPlaced","destination_type":"queue","routing_key":"OrderPlaced","arguments":{}}]}
'@ | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -e RABBITMQ_DEFAULT_USER=flashsale -e RABBITMQ_DEFAULT_PASS=flashsale_dev `
        -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${BrokerPort}:5672" -p "${BrokerMgmtPort}:15672" rabbitmq:3-management | Out-Null
    $auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
    $published = $false
    for ($i = 0; $i -lt 60 -and -not $published; $i++) {
        Start-Sleep 2
        $published = (OutboxFor $k1).StartsWith("true|")
    }
    Check "retries: once the broker is up the row is marked published" $published
    $msgs = @(Invoke-RestMethod -Method Post -Headers $auth -ContentType "application/json" `
        -Body '{"count":100,"ackmode":"ack_requeue_false","encoding":"auto"}' "http://localhost:$BrokerMgmtPort/api/queues/%2F/OrderPlaced/get")
    # Windows PowerShell 5.1 returns a JSON array as ONE pipeline object;
    # unroll it so each message is filtered on its own.
    $msgs = @($msgs | ForEach-Object { $_ })
    Check "broker: capture queue holds one message per published order (2 orders were created)" ($msgs.Count -eq 2) "$($msgs.Count) messages"
    $forOrder = @($msgs | Where-Object { ($_.payload | ConvertFrom-Json).OrderId -eq $orderId })
    Check "retries: exactly one OrderPlaced for the order reached the queue" ($forOrder.Count -eq 1) "$($forOrder.Count) messages"
    if ($forOrder.Count -ge 1) {
        $sentId = [string](($forOrder[0].payload | ConvertFrom-Json).MessageId)
        Check "retries: delivered MessageId equals the one stored at commit time ($messageId)" ([string]$sentId -eq [string]$messageId) "delivered $sentId"
    }
    $rowsAfter = [int](Sql "SELECT count(*) FROM order_service.outbox_events e JOIN order_service.orders o ON o.`"Id`" = e.`"OrderId`" WHERE o.`"IdempotencyKey`" = '$k1';")
    Check "retries: still exactly one Outbox row for the order (no re-insert)" ($rowsAfter -eq 1)
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    if ($svc) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
    }
    docker rm -f $mq *> $null
    Sql "GRANT INSERT ON order_service.outbox_events TO order_service_user;" | Out-Null
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Outbox commit/rollback and stable MessageId verified." -ForegroundColor Green
