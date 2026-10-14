# ============================================================
# Week 8 TP-W02 (real runs): runs a real C1 workload and a real end-to-end C2
# workload, then validates both with scripts/validate-correctness.ps1.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-real-runs.ps1 -Container verify-env-pg -DbPort 55432
#
# C1: 30 concurrent POST /api/c1/orders against 20 units.
# C2: Order Service + Inventory Service + Process Worker on a throwaway
#     RabbitMQ and Redis; warm-up 20 units; 30 concurrent orders (distinct
#     keys) plus 10 client retries; wait until no order is PendingStock.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$mq = "verify-rr-mq"; $amqp = 5685; $mgmt = 15685; $redis = "verify-rr-redis"; $redisPort = 6395
$orderPort = 5117; $invPort = 5118; $workerPort = 5119
$ex = "flashsale.order.exchange"
$started = @()
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql) { $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -; return (@($out | Where-Object { $_ -ne "" }) -join "`n") }
function Mq([string]$method, [string]$path) { try { return Invoke-RestMethod -Method $method -Headers $auth -Uri "http://localhost:$mgmt/api$path" -TimeoutSec 10 } catch { return $null } }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Start-Svc([string]$project, [hashtable]$envs) {
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-rr-$project.log"
    $p = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:started += $p
}
function Validate([string]$config, [string]$product, [int]$initial) {
    $out = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config $config -ProductId $product -InitialStock $initial -PgContainer $Container -RedisContainer $redis *>&1 | Out-String
    Write-Host $out.Trim()
    return $LASTEXITCODE
}
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
[System.Net.ServicePointManager]::DefaultConnectionLimit = 1000
function Post-Many([string]$url, [object[]]$requests) {
    $tasks = @(foreach ($r in $requests) {
        $m = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
        if ($r.Key) { $m.Headers.TryAddWithoutValidation("Idempotency-Key", $r.Key) | Out-Null }
        $m.Content = New-Object System.Net.Http.StringContent($r.Body, [Text.Encoding]::UTF8, "application/json")
        $client.SendAsync($m)
    })
    try { [System.Threading.Tasks.Task]::WaitAll($tasks) } catch { }
    return @($tasks | ForEach-Object { if ($_.IsFaulted) { -1 } else { [int]$_.Result.StatusCode } })
}

# Fresh product ids per run: the database is shared across runs, and leftover
# orders from an earlier run would (correctly) make the validator fail.
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$c1Product = "rr-c1-$runId"; $c2Product = "rr-c2-$runId"
try {
    $bash = { param($c) docker rm -f $c *> $null }
    & $bash $mq; & $bash $redis
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-rr-definitions.json"; $conf = Join-Path $env:TEMP "verify-rr-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $hash = [Convert]::ToBase64String($salt + [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev")))
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(@{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
    } | ConvertTo-Json -Depth 5 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    $pg = "Host=localhost;Port=$DbPort;Database=flashsale"
    Start-Svc "FlashSale.OrderService" @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    Start-Svc "FlashSale.InventoryService" @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    Start-Svc "FlashSale.ProcessWorker" @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
    $queues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessed", "ProcessWorker.StockReserved"
    $ready = Wait-Until { @($queues | Where-Object { $null -eq (Mq Get "/queues/%2F/$_") }).Count -eq 0 } 120
    Check "all three services up; all five consumer queues declared" $ready

    # ---------- C1 real run ----------
    "DELETE FROM order_service.baseline_orders WHERE product_id = '$c1Product'; INSERT INTO order_service.inventory VALUES ('$c1Product', 20) ON CONFLICT (product_id) DO UPDATE SET stock = 20;" | docker exec -i $Container psql -U flashsale -d flashsale -q -f - | Out-Null
    $codes = Post-Many "http://localhost:$orderPort/api/c1/orders" @(1..30 | ForEach-Object { @{ Key = $null; Body = ('{"productId":"' + $c1Product + '"}') } })
    Check "C1: 30 concurrent requests all answered 200" (@($codes | Where-Object { $_ -ne 200 }).Count -eq 0) (($codes | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ",")
    Check "C1 real run: validator passes (20 units, 30 requests)" ((Validate C1 $c1Product 20) -eq 0)

    # ---------- C2 real run ----------
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $c2Product = 20 } -Force *> $null
    $keys = @(1..30 | ForEach-Object { "rr-" + [guid]::NewGuid() })
    $reqs = @($keys | ForEach-Object { @{ Key = $_; Body = ('{"productId":"' + $c2Product + '","quantity":1}') } }) + @($keys[0..9] | ForEach-Object { @{ Key = $_; Body = ('{"productId":"' + $c2Product + '","quantity":1}') } })
    $codes = Post-Many "http://localhost:$orderPort/api/orders" $reqs
    Check "C2: 40 concurrent requests (30 keys + 10 retries) all accepted (201/200)" (@($codes | Where-Object { $_ -notin 200, 201 }).Count -eq 0) (($codes | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ",")
    $settled = Wait-Until { (Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$c2Product' AND `"State`" IN ('PendingStock','Confirmed');") -eq "0" } 120
    $states = Sql "SELECT `"State`" || '=' || count(*) FROM order_service.orders WHERE `"ProductId`" = '$c2Product' GROUP BY `"State`" ORDER BY `"State`";"
    Check "C2: every order settled (Completed or Rejected): $($states -replace "`n", ', ')" $settled
    Check "C2: exactly 30 orders for 30 keys, 20 Completed and 10 Rejected" ($states -eq "Completed=20`nRejected=10") ($states -replace "`n", ', ')
    Check "C2 real run: validator passes (20 units, 30 orders)" ((Validate C2 $c2Product 20) -eq 0)
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
Write-Host "Real C1 and C2 runs validate: all four invariants hold." -ForegroundColor Green
