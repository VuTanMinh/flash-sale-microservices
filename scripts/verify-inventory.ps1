# ============================================================
# Week 7 TP-I01 / TP-I02 (docs/inventory.md): warm-up readiness, Lua outcomes,
# concurrent hot-product and skewed multi-product traffic, per-product
# invariants -- against a throwaway Redis, plus an end-to-end readiness check
# through Inventory Service (throwaway broker, migrated throwaway database).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-inventory.ps1 -Container verify-env-pg -DbPort 55432
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$redis = "verify-inv-redis"; $redisPort = 6393
$mq = "verify-inv-mq"; $amqp = 5682; $mgmt = 15682; $invPort = 5114
$ex = "flashsale.order.exchange"
$svc = $null
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Probe([string[]]$probeArgs) {
    $out = dotnet run --project (Join-Path $repoRoot "tests\InventoryProbe") --no-build -- @probeArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $out.Trim().Split("`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(PASS|FAIL|INFO)' } | ForEach-Object {
        if ($_ -like "PASS*") { Write-Host $_ -ForegroundColor Green } elseif ($_ -like "FAIL*") { Write-Host $_ -ForegroundColor Red } else { Write-Host $_ }
    }
    if ($code -ne 0) { $script:failures++ }
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

try {
    dotnet build (Join-Path $repoRoot "tests\InventoryProbe") -nologo -v q *> $null
    docker rm -f $redis $mq *> $null
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    Start-Sleep 3

    # TP-I01 readiness: before warm-up nothing can be reserved
    Probe @("localhost:$redisPort", "not-open", "hot-product")

    # Warm-up (atomic + confirmed), re-run guard. Called in-process with & so the
    # product hashtable can be passed (powershell -File only passes strings).
    $products = @{ "hot-product" = 100; "skew-a" = 40; "skew-b" = 30; "skew-c" = 20; "skew-d" = 10; "e2e-product" = 1 }
    $wu = & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products $products *>&1 | Out-String
    Check "TP-I01 warm-up exits 0 and confirms all 6 products" ($LASTEXITCODE -eq 0 -and ([regex]::Matches($wu, "CONFIRMED")).Count -eq 6) $wu.Trim()
    Redis @("DECR", "inventory:skew-d") | Out-Null
    $wu2 = & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ "skew-d" = 10 } *>&1 | Out-String
    Check "TP-I01 re-running warm-up on an open sale is refused (stock not reset)" ($wu2 -match "SKIP" -and (Redis @("GET", "inventory:skew-d")) -eq "9")
    $wu3 = & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ "skew-d" = 10 } -Force *>&1 | Out-String
    Check "TP-I01 -Force resets and re-confirms" ($wu3 -match "CONFIRMED" -and (Redis @("GET", "inventory:skew-d")) -eq "10")

    # TP-I02 hot product: 400 concurrent requests (300 distinct orders + 100 repeats) on 100 units
    Probe @("localhost:$redisPort", "burst", "hot-product=100", "300", "100")
    # TP-I02 skewed: 250 distinct orders over 4 products weighted 50/25/15/10, + 80 repeats
    Probe @("localhost:$redisPort", "burst", "skew-a=40,skew-b=30,skew-c=20,skew-d=10", "250", "80", "50,25,15,10")

    # End-to-end readiness through Inventory Service
    $defs = Join-Path $env:TEMP "verify-inv-definitions.json"; $conf = Join-Path $env:TEMP "verify-inv-rabbitmq.conf"
    $salt = New-Object byte[] 4; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $hash = [Convert]::ToBase64String($salt + [Security.Cryptography.SHA256]::Create().ComputeHash($salt + [Text.Encoding]::UTF8.GetBytes("flashsale_dev")))
    $queues = @("StockReserved", "ProcessWorker.StockReserved", "StockRejected")
    @{
        users = @(@{ name = "flashsale"; password_hash = $hash; hashing_algorithm = "rabbit_password_hashing_sha256"; tags = @("administrator") })
        permissions = @(@{ user = "flashsale"; vhost = "/"; configure = ".*"; write = ".*"; read = ".*" })
        vhosts = @(@{ name = "/" })
        exchanges = @(@{ name = $ex; vhost = "/"; type = "direct"; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
        queues = @($queues | ForEach-Object { @{ name = $_; vhost = "/"; durable = $true; auto_delete = $false; arguments = @{} } })
    } | ConvertTo-Json -Depth 5 | Set-Content $defs -Encoding ASCII
    "management.load_definitions = /etc/rabbitmq/definitions.json`nloopback_users = none`n" | Set-Content $conf -Encoding ASCII
    docker run -d --name $mq -v "${defs}:/etc/rabbitmq/definitions.json:ro" -v "${conf}:/etc/rabbitmq/conf.d/90-verify.conf:ro" `
        -p "${amqp}:5672" -p "${mgmt}:15672" rabbitmq:3-management | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "throwaway RabbitMQ did not start" }

    $log = Join-Path $env:TEMP "verify-inv-inventory-service.log"
    $envs = @{ ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"
               ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.InventoryService") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    if (-not (Wait-Until { $null -ne (Mq Get "/queues/%2F/OrderPlaced") } 90)) { throw "Inventory Service did not declare its OrderPlaced queue; see $log" }

    $cases = @(@{ Product = "never-warmed"; Expect = "StockRejected" }, @{ Product = "e2e-product"; Expect = "StockReserved" })
    foreach ($c in $cases) {
        $c.Order = [guid]::NewGuid()
        $placed = "{`"OrderId`":`"$($c.Order)`",`"ProductId`":`"$($c.Product)`",`"Quantity`":1,`"MessageId`":`"$([guid]::NewGuid())`",`"CorrelationId`":`"verify-inventory`"}"
        Mq Post "/exchanges/%2F/$ex/publish" @{ properties = @{ type = "OrderPlaced"; content_type = "application/json" }; routing_key = "OrderPlaced"; payload = $placed; payload_encoding = "string" } | Out-Null
    }
    foreach ($c in $cases) {
        $ok = Wait-Until { (Sql "SELECT `"EventType`" FROM inventory_service.outbox_events WHERE `"OrderId`" = '$($c.Order)';") -ne "" } 30
        $type = Sql "SELECT `"EventType`" FROM inventory_service.outbox_events WHERE `"OrderId`" = '$($c.Order)';"
        Check "TP-I01 end to end: OrderPlaced for '$($c.Product)' -> $($c.Expect)" ($ok -and $type -eq $c.Expect) "got '$type'"
    }
    Check "TP-I01 end to end: no stock created or reserved for the never-warmed product" ((Redis @("EXISTS", "inventory:never-warmed")) -eq "0" -and (Redis @("SCARD", "processed:never-warmed")) -eq "0")
    Check "TP-I01 end to end: Inventory Service logged the NotOpen result" (@(Select-String -Path $log -Pattern "never-warmed -> NotOpen").Count -ge 1)
    Check "TP-I01 end to end: the warmed product's single unit is now reserved" ((Redis @("GET", "inventory:e2e-product")) -eq "0" -and (Redis @("SCARD", "processed:e2e-product")) -eq "1")
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    if ($svc) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
    }
    docker rm -f $redis $mq *> $null
}
Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Warm-up readiness, Lua outcomes and per-product invariants verified." -ForegroundColor Green
