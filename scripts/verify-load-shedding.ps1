# ============================================================
# Week 12 TP-L01 + TP-L02 (docs/load-shedding.md): the three C3 overload layers
# shed load early, the Outbox-backlog bound (box 2) refuses new orders when the
# Outbox is already full, and C2 (every limit off) is unchanged.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-load-shedding.ps1 -Container verify-env-pg -DbPort 55432
#
# Starts its own throwaway RabbitMQ (5701/15701), Redis (6411) and Nginx (8090),
# plus Order Service (5163), Inventory Service (5164) and the Process Worker
# (5165) against the given PostgreSQL container.
#
# Cases:
#   A. Gateway rate limit: Nginx with a low ORDER_RATE (5r/s, burst 1). ~40
#      POSTs through Nginx; some get 429, every 201 has an order row, no order
#      row for any 429 key, and GET polling through Nginx is never 429. The
#      same bucket also limits the non-canonical POST /api/orders/ and
#      /API/orders (trailing slash / letter case), with no order row for those
#      429 keys.
#   B. Application admission: Order Service restarted with Admission:Enabled,
#      MaxConcurrentNewOrders=2 and a 1500 ms test hold. The gate is saturated,
#      the 503s carry Retry-After and are counted by
#      flashsale_admission_rejected_total{reason="concurrency"}, no 503 key has
#      an order row, and a replay of an accepted key returns 200 while the gate
#      is full.
#   C. Bounded queue + publisher at capacity: a max-length=3 policy on the six
#      main queues, Inventory stopped, 8 orders. All 8 get 201, OrderPlaced
#      depth stays <= 3, the Outbox holds the other 5 unpublished; starting
#      Inventory drains everything with one reservation per order.
#   D. C2 unchanged: policy removed and admission off, 8 orders are all
#      accepted and processed (no 429/503/nack).
#   E. Outbox-backlog admission (box 2): Order Service restarted with
#      Admission:Enabled, MaxConcurrentNewOrders high (so only the backlog
#      bound can refuse) and MaxOutboxBacklog=5, then the throwaway broker is
#      stopped so every publish fails and the Outbox grows 1:1 with accepted
#      orders. Some 201s, then 503 with Retry-After and
#      flashsale_admission_rejected_total{reason="backlog"} rising by exactly
#      the 503 count; no order/Outbox row for a 503 key and Redis unchanged; a
#      replay of an accepted key returns 200 while the backlog is full. The
#      broker is restored: the Outbox drains to 0, every accepted order
#      completes, new orders are admitted again (201), SCARD = accepted and
#      stock = initial - accepted.
#   F. Validator -Config C3 (box 2 check 5): validate-correctness.ps1 passes on
#      E's product after the drain (check 5 PASS); then Inventory is stopped, one
#      last order is left PendingStock, and the validator is INCONCLUSIVE with
#      that order listed and exit 1.
#   G. Backlog is tracked: collect-run-metrics.ps1 sampled during E; its CSV has
#      flashsale_outbox_unpublished, flashsale_admission_rejected_total with
#      reason=backlog, and a RabbitMQ queue depth, with the backlog rising above
#      0 while the broker is down.
#
# Negative controls (Claude runs them): admission disabled -> B fails; policy
# not set -> C fails; Nginx rate set very high -> A fails; MaxOutboxBacklog=0
# -> E fails; check 5 removed -> F's negative fixture passes wrongly (F fails).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 30     # number of Check calls in the try block (a truncated run must fail)
$mq = "verify-ls-mq"; $amqp = 5701; $mgmt = 15701; $redis = "verify-ls-redis"; $redisPort = 6411
$nginx = "verify-ls-nginx"; $nginxPort = 8090
$orderPort = 5163; $invPort = 5164; $workerPort = 5165
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__StuckTimeoutSeconds = "3600" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp" }
}
$orderAdmissionOn = @{ Admission__Enabled = "true"; Admission__MaxConcurrentNewOrders = "2"; FaultInjection__AdmissionHoldMilliseconds = "1500" }
$logs = @{}   # project -> current log file
$runId = (Get-Date).ToUniversalTime().ToString("HHmmss")
$pA = "ls-a-$runId"; $pB = "ls-b-$runId"; $pC = "ls-c-$runId"; $pD = "ls-d-$runId"
$pAStock = 100; $pBStock = 50; $pCStock = 20; $pDStock = 20
$pE = "ls-e-$runId"; $pEStock = 30
$allQueues = "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"
$allDlqs = "OrderPlaced.dlq", "StockReserved.dlq", "StockRejected.dlq", "OrderProcessingStarted.dlq", "OrderProcessed.dlq", "ProcessWorker.StockReserved.dlq"

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
    if ($v -notmatch '^\d+$') { return -1 }
    return [int]$v
}
function Mq([string]$method, [string]$path, $body = $null) {
    $req = @{ Method = $method; Headers = $auth; Uri = "http://localhost:$mgmt/api$path"; TimeoutSec = 10 }
    if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 20 -Compress); $req.ContentType = "application/json" }
    try { return Invoke-RestMethod @req } catch { return $null }
}
function QueueDepth([string]$q) {
    $line = docker exec $mq rabbitmqctl -q list_queues name messages --no-table-headers 2>$null | Where-Object { ($_ -split "`t")[0] -eq $q }
    if ($line) { return [int](($line -split "`t")[1]) } else { return -1 }
}
function QueueExists([string]$q) { return ($null -ne (Mq Get "/queues/%2F/$q")) }
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis-Cmd([string[]]$cmd) { return (docker exec $redis redis-cli @cmd | Out-String).Trim() }
function Stock([string]$product) { return (Redis-Cmd "GET", "inventory:$product") }
function Scard([string]$product) { return [int](Redis-Cmd "SCARD", "processed:$product") }
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
function Start-Svc([string]$project, [string]$tag, [hashtable]$extra = @{}) {
    $envs = @{} + $svcEnv[$project] + $extra
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $env:TEMP "verify-ls-$project-$tag.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 90 | Out-Null
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function AllCompleted([string[]]$ids) { foreach ($id in $ids) { if ((State $id) -ne "Completed") { return $false } }; return $true }
function OrderRowCount([string]$key) { return (Int1 "SELECT count(*) FROM order_service.orders WHERE `"IdempotencyKey`" = '$key';") }
function UnpublishedRows() { return (Int1 "SELECT count(*) FROM order_service.outbox_events WHERE `"Published`" = false;") }
# Direct POST to Order Service (admission off path), returns the order id or "".
function Post-Direct([string]$key, [string]$product) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = $key } -Body ('{"productId":"' + $product + '","quantity":1}') `
            "http://localhost:$orderPort/api/orders" -TimeoutSec 15
        return "$(($r.Content | ConvertFrom-Json).id)"
    } catch { return "" }
}
# POST through Nginx; returns @{ Status; Id } (Id from a 201/200 body). -Path is
# the request path (default /api/orders). Case A uses /api/orders/, /API/orders
# and /api/orders to prove the server-level limit covers non-canonical paths.
function Post-Nginx([string]$key, [string]$product, [string]$Path = "/api/orders") {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = $key } -Body ('{"productId":"' + $product + '","quantity":1}') `
            "http://localhost:$nginxPort$Path" -TimeoutSec 15
        return @{ Status = [int]$r.StatusCode; Id = ($r.Content | ConvertFrom-Json).id }
    } catch {
        $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ Status = $code; Id = $null }
    }
}
function Get-Nginx([string]$id) {
    try { $r = Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxPort/api/orders/$id" -TimeoutSec 15; return [int]$r.StatusCode }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }; return 0 }
}
# --- HttpClient helpers (true parallelism for case B, where blocking sequential
# --- requests would never saturate the gate) --------------------------------
# PS 5.1 runs on .NET Framework: it does not load System.Net.Http by default,
# and its per-host connection limit is 2 (two concurrent "blocker" requests
# would starve the third). Load the assembly, raise the limit, and fail fast
# rather than silently continuing if the client cannot be created.
Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::DefaultConnectionLimit = 100
$http = New-Object System.Net.Http.HttpClient
if ($null -eq $http) { throw "SETUP ERROR: could not create System.Net.Http.HttpClient" }
function New-Body([string]$key, [string]$product) {
    # Build the JSON into a variable first: in PowerShell argument mode the comma
    # binds tighter than +, so New-Object with an inline concatenation collapses
    # the three arguments into one string and picks the single-string (text/plain)
    # constructor, which the API rejects with 415. ::new with a pre-built variable
    # avoids that trap.
    $json = '{"productId":"' + $product + '","quantity":1}'
    $c = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, "application/json")
    $c.Headers.Add("Idempotency-Key", $key)
    return $c
}
function Resp-To($resp) {
    $status = [int]$resp.StatusCode
    $body = $resp.Content.ReadAsStringAsync().Result
    $retry = ""
    try { $retry = ($resp.Headers.GetValues("Retry-After") | Select-Object -First 1) } catch { $retry = "" }
    $id = $null
    if ($status -eq 200 -or $status -eq 201) { try { $id = ($body | ConvertFrom-Json).id } catch { $id = $null } }
    return @{ Status = $status; RetryAfter = $retry; Id = $id }
}
function Post-Http([string]$key, [string]$product) {
    return (Resp-To ($http.PostAsync("http://localhost:$orderPort/api/orders", (New-Body $key $product)).Result))
}
function Scrape-Order() {
    try { return (Invoke-WebRequest -UseBasicParsing "http://localhost:$orderPort/metrics" -TimeoutSec 10).Content } catch { return "" }
}
function AdmissionRejectedTotal() {
    $sum = 0.0
    foreach ($line in ((Scrape-Order) -split "`n")) {
        if ($line -match '^flashsale_admission_rejected_total\{reason="concurrency"\}\s+(\S+)') { $sum += [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
    }
    return $sum
}
function AdmissionRejectedBacklogTotal() {
    $sum = 0.0
    foreach ($line in ((Scrape-Order) -split "`n")) {
        if ($line -match '^flashsale_admission_rejected_total\{reason="backlog"\}\s+(\S+)') { $sum += [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
    }
    return $sum
}
function OutboxUnpublished() {
    foreach ($line in ((Scrape-Order) -split "`n")) {
        if ($line -match '^flashsale_outbox_unpublished\s+(\S+)') { return [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
    }
    return 0.0
}

# ================================================================== run
try {
    # ---------------------------------------------------------- guards
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed); this verifier needs Docker" }
    if ((Int1 "SELECT 1;" "flashsale") -ne 1) { throw "SETUP ERROR: cannot query container '$Container'; run scripts\verify-environment.ps1 -Mode Fresh -Keep first" }
    foreach ($port in $orderPort, $invPort, $workerPort, $nginxPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use" }
    }
    foreach ($c in $mq, $redis, $nginx) { docker rm -f $c *> $null }

    # ---------------------------------------------------------- throwaway stack
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $env:TEMP "verify-ls-definitions.json"; $conf = Join-Path $env:TEMP "verify-ls-rabbitmq.conf"
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
    Check "all three services up; every queue and DLQ declared" $ready (($all | ForEach-Object { "$_=$(QueueDepth $_)" }) -join ",")
    if (-not $ready) { throw "services did not come up" }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $pA = $pAStock; $pB = $pBStock; $pC = $pCStock; $pD = $pDStock; $pE = $pEStock } -Force *> $null
    Check "warm-up: pA=$pAStock, pB=$pBStock, pC=$pCStock, pD=$pDStock, pE=$pEStock" ((Stock $pA) -eq "$pAStock" -and (Stock $pB) -eq "$pBStock" -and (Stock $pC) -eq "$pCStock" -and (Stock $pD) -eq "$pDStock" -and (Stock $pE) -eq "$pEStock")

    # ---------------------------------------------------------- A. gateway
    Write-Output "== A. Gateway rate limit (Nginx ORDER_RATE=5r/s, burst 1)"
    $nginxTemplate = Join-Path $repoRoot "infra\nginx.conf"
    docker run -d --name $nginx -e "ORDER_UPSTREAM=host.docker.internal:$orderPort" -e "ORDER_SCHEME=http" -e "ORDER_RATE=5r/s" -e "ORDER_BURST=1" `
        -p "${nginxPort}:80" -v "${nginxTemplate}:/etc/nginx/templates/default.conf.template:ro" nginx:latest | Out-Null
    if (-not (Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxPort/nginx-health" -TimeoutSec 3).StatusCode -eq 200 } catch { $false } } 60)) {
        throw "Nginx container did not start (envsubst template failed?)"
    }
    $a201 = @(); $a429 = @()
    for ($i = 0; $i -lt 40; $i++) {
        $key = "ls-a-$i-" + [guid]::NewGuid()
        $r = Post-Nginx $key $pA "/api/orders"
        if ($r.Status -eq 201) { $a201 += @{ Key = $key; Id = $r.Id } }
        elseif ($r.Status -eq 429) { $a429 += @{ Key = $key } }
    }
    # R10: the same bucket must cover the non-canonical paths ASP.NET accepts
    # (a trailing slash, and any letter case), not only the canonical /api/orders.
    # Box 3: with the catch-all now `return 404`, a wrong-case /API/orders is
    # answered 404 in the rewrite phase (before limit_req) -- never 201 and
    # never reaching Order Service. /api/orders/ reaches the rate-limited
    # location, so it is accepted (201) when the bucket has room and 429 when it
    # does not.
    $aTrail = @()
    for ($i = 0; $i -lt 10; $i++) {
        $key = "ls-at-$i-" + [guid]::NewGuid()
        $aTrail += @{ Key = $key; Status = (Post-Nginx $key $pA "/api/orders/").Status }
    }
    $aCase = @()
    for ($i = 0; $i -lt 10; $i++) {
        $key = "ls-ac-$i-" + [guid]::NewGuid()
        $aCase += @{ Key = $key; Status = (Post-Nginx $key $pA "/API/orders").Status }
    }
    # Trailing slash: at least one 429, each 201 has exactly one order row, and
    # no 429 key has an order row.
    $a429Trail = @($aTrail | Where-Object { $_.Status -eq 429 })
    $aTrail201 = @($aTrail | Where-Object { $_.Status -eq 201 })
    $aTrailRowsOk = $true
    foreach ($r in $aTrail201) { if ((OrderRowCount $r.Key) -ne 1) { $aTrailRowsOk = $false } }
    foreach ($r in $a429Trail) { if ((OrderRowCount $r.Key) -ne 0) { $aTrailRowsOk = $false } }
    # Wrong case: never 201 (429 or 404), and no order row.
    $aCaseNever201 = $true
    foreach ($r in $aCase) { if ($r.Status -eq 201) { $aCaseNever201 = $false } }
    $aCaseNoRow = $true
    foreach ($r in $aCase) { if ((OrderRowCount $r.Key) -ne 0) { $aCaseNoRow = $false } }
    $a429All = @($a429) + @($a429Trail)
    $aMixed = ($a201.Count -gt 0) -and ($a429.Count -gt 0)
    $aRowsOk = $true
    foreach ($r in $a201) { if ((OrderRowCount $r.Key) -ne 1) { $aRowsOk = $false } }
    foreach ($r in $a429All) { if ((OrderRowCount $r.Key) -ne 0) { $aRowsOk = $false } }
    Check "A: some POSTs through Nginx get 429 and some get 201" $aMixed "201=$($a201.Count) 429=$($a429.Count)"
    Check "A: /api/orders/ gets >=1 429 (201s one row, 429s none) and /API/orders is never 201 with no row" ($a429Trail.Count -gt 0 -and $aTrailRowsOk -and $aCaseNever201 -and $aCaseNoRow) "trailing-429=$($a429Trail.Count) trailing-201=$($aTrail201.Count) case-statuses=$(@($aCase | ForEach-Object { $_.Status }) -join ',')"
    Check "A: every 201 has an order row and no 429 key (any path) has an order row" ($aRowsOk -and $a201.Count -gt 0 -and $a429All.Count -gt 0) "201-keys=$($a201.Count) 429-keys=$($a429All.Count)"
    $aGetNever429 = $true
    if ($a201.Count -gt 0) {
        $pollId = $a201[0].Id
        for ($i = 0; $i -lt 15; $i++) { if ((Get-Nginx $pollId) -eq 429) { $aGetNever429 = $false } }
    }
    Check "A: GET polling through Nginx is never 429" ($aGetNever429 -and $a201.Count -gt 0) "polled $($a201[0].Id) 15 times"
    # Box 3 (gateway exposure): only the API under test is proxied. Swagger and
    # the ABP admin UI must be 404 through Nginx, while /api/orders still works.
    $swaggerStatus = 0; $loginStatus = 0
    try { $swaggerStatus = [int](Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxPort/swagger/index.html" -TimeoutSec 10).StatusCode }
    catch { if ($_.Exception.Response) { $swaggerStatus = [int]$_.Exception.Response.StatusCode } }
    try { $loginStatus = [int](Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxPort/Account/Login" -TimeoutSec 10).StatusCode }
    catch { if ($_.Exception.Response) { $loginStatus = [int]$_.Exception.Response.StatusCode } }
    Check "A: gateway returns 404 for /swagger/index.html and /Account/Login (only the API is exposed)" ($swaggerStatus -eq 404 -and $loginStatus -eq 404 -and $a201.Count -gt 0) "swagger=$swaggerStatus login=$loginStatus"
    docker rm -f $nginx *> $null

    # ---------------------------------------------------------- B. admission
    Write-Output "== B. Application admission (MaxConcurrentNewOrders=2, hold 1500 ms)"
    Stop-Svc "FlashSale.OrderService"
    Start-Svc "FlashSale.OrderService" "adm" $orderAdmissionOn
    # Pre-seed one accepted order (K0) whose row is committed before the gate is saturated.
    $k0 = "ls-b0-" + [guid]::NewGuid()
    $r0 = Post-Http $k0 $pB
    Check "B: pre-seeded order accepted (201)" ($r0.Status -eq 201 -and $null -ne $r0.Id) "status=$($r0.Status)"
    $k0Id = $r0.Id
    # Saturate the gate: two blockers grab both slots and hold for 1500 ms.
    $k1 = "ls-b1-" + [guid]::NewGuid(); $k2 = "ls-b2-" + [guid]::NewGuid()
    $t1 = $http.PostAsync("http://localhost:$orderPort/api/orders", (New-Body $k1 $pB))
    $t2 = $http.PostAsync("http://localhost:$orderPort/api/orders", (New-Body $k2 $pB))
    Start-Sleep -Milliseconds 400
    $rejBefore = AdmissionRejectedTotal
    # Fire 8 new keys while the gate is full: each must be a 503.
    $b503 = @(); $b201 = @()
    for ($i = 3; $i -le 10; $i++) {
        $key = "ls-b$i-" + [guid]::NewGuid()
        $rr = Post-Http $key $pB
        if ($rr.Status -eq 503) { $b503 += @{ Key = $key; RetryAfter = $rr.RetryAfter } }
        elseif ($rr.Status -eq 201) { $b201 += @{ Key = $key; Id = $rr.Id } }
    }
    # Replay the accepted key while the gate is still held full.
    $rReplay = Post-Http $k0 $pB
    # Now let the two blockers finish (they return 201 after the hold).
    $r1 = Resp-To $t1.Result
    $r2 = Resp-To $t2.Result
    if ($r1.Status -eq 201) { $b201 += @{ Key = $k1; Id = $r1.Id } }
    if ($r2.Status -eq 201) { $b201 += @{ Key = $k2; Id = $r2.Id } }
    $rejAfter = AdmissionRejectedTotal
    $bAllHaveRetry = $true
    foreach ($r in $b503) { if (-not $r.RetryAfter) { $bAllHaveRetry = $false } }
    $bNoRowFor503 = $true
    foreach ($r in $b503) { if ((OrderRowCount $r.Key) -ne 0) { $bNoRowFor503 = $false } }
    Check "B: at least one 503 with Retry-After and at most 2 (Max) 201s" ($b503.Count -ge 1 -and $bAllHaveRetry -and $b201.Count -le 2) "503=$($b503.Count) 201=$($b201.Count)"
    Check "B: no order row exists for any 503 key" ($bNoRowFor503 -and $b503.Count -gt 0) "503-keys=$($b503.Count)"
    Check "B: flashsale_admission_rejected_total{reason=concurrency} rose by exactly the 503 count" ($b503.Count -gt 0 -and ($rejAfter - $rejBefore) -eq $b503.Count) "before=$rejBefore after=$rejAfter 503=$($b503.Count)"
    Check "B: replay of an accepted key returns 200 with the original order while the gate is full" ($rReplay.Status -eq 200 -and $rReplay.Id -eq $k0Id) "replay=$($rReplay.Status) id-match=$($rReplay.Id -eq $k0Id)"
    Stop-Svc "FlashSale.OrderService"
    Start-Svc "FlashSale.OrderService" "c2"
    # Let A and B's orders finish publishing so C's Outbox accounting below
    # counts only C's own 8 orders.
    Wait-Until { (UnpublishedRows) -eq 0 } 90 | Out-Null

    # ---------------------------------------------------------- C. bounded queue
    Write-Output "== C. Bounded queue + publisher at capacity (max-length 3)"
    & (Join-Path $repoRoot "scripts\set-queue-bounds.ps1") -Container $mq -MaxLength 3 *> $null
    Stop-Svc "FlashSale.InventoryService"
    $cIds = @(); $cAll201 = $true
    for ($i = 0; $i -lt 8; $i++) {
        $id = Post-Direct ("ls-c$i-" + [guid]::NewGuid()) $pC
        if (-not $id) { $cAll201 = $false } else { $cIds += $id }
    }
    Check "C: all 8 orders get 201 with the queue bounded and Inventory stopped" ($cAll201 -and $cIds.Count -eq 8) "orders=$($cIds.Count)"
    $cBounded = Wait-Until { (QueueDepth "OrderPlaced") -eq 3 } 90
    $cUnpub = Wait-Until { (UnpublishedRows) -eq 5 -and (OutboxUnpublished) -ge 5 } 120
    Check "C: OrderPlaced depth is bounded at 3 by the max-length policy" ($cBounded -and (QueueDepth "OrderPlaced") -le 3) "depth=$(QueueDepth 'OrderPlaced')"
    Check "C: the Order Outbox holds the other 5 unpublished (gauge >= 5, rows in the table)" ($cUnpub -and (UnpublishedRows) -eq 5 -and (OutboxUnpublished) -ge 5) "unpublished-rows=$(UnpublishedRows) gauge=$(OutboxUnpublished)"
    Start-Svc "FlashSale.InventoryService" "c"
    $cDone = Wait-Until { AllCompleted $cIds } 120
    $cDrained = Wait-Until { (UnpublishedRows) -eq 0 -and (OutboxUnpublished) -eq 0 } 120
    Check "C: after Inventory starts, the Outbox drains to 0 and every order completes" ($cDone -and $cDrained) "completed=$cDone drained=$cDrained unpublished=$(UnpublishedRows)"
    Check "C: one reservation per order (SCARD processed=8, stock=initial-8)" ((Scard $pC) -eq 8 -and (Stock $pC) -eq "$($pCStock - 8)") "scard=$(Scard $pC) stock=$(Stock $pC)"

    # ---------------------------------------------------------- D. C2 unchanged
    Write-Output "== D. C2 unchanged (policy removed, admission off)"
    & (Join-Path $repoRoot "scripts\set-queue-bounds.ps1") -Container $mq -Remove *> $null
    $dIds = @(); $dAll201 = $true
    for ($i = 0; $i -lt 8; $i++) {
        $id = Post-Direct ("ls-d$i-" + [guid]::NewGuid()) $pD
        if (-not $id) { $dAll201 = $false } else { $dIds += $id }
    }
    $dDone = Wait-Until { AllCompleted $dIds } 120
    $dDrained = Wait-Until { (UnpublishedRows) -eq 0 } 90
    Check "D: with the policy removed and admission off, 8 orders are all accepted (201)" ($dAll201 -and $dIds.Count -eq 8) "orders=$($dIds.Count)"
    Check "D: all 8 complete and the Outbox drains with no nack" ($dDone -and $dDrained) "completed=$dDone drained=$dDrained unpublished=$(UnpublishedRows)"

    # ---------------------------------------------------------- E. backlog admission
    Write-Output "== E. Backlog admission with the broker unavailable (MaxOutboxBacklog=5)"
    Stop-Svc "FlashSale.OrderService"
    $eMaxBacklog = 5
    Start-Svc "FlashSale.OrderService" "backlog" @{ Admission__Enabled = "true"; Admission__MaxConcurrentNewOrders = "1000"; Admission__MaxOutboxBacklog = "$eMaxBacklog" }

    # G. sample the run with collect-run-metrics.ps1 in the background across E
    # (broker up -> down -> up), so its CSV sees the backlog rise and the queue.
    # A fresh per-run folder: a stale STOP from an earlier run must not make the
    # collector exit before its first sample (review R4).
    $collectorOutDir = Join-Path $env:TEMP ("verify-ls-collector-e-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $collectorOutDir | Out-Null
    $collectorArgs = @(
        "-File", (Join-Path $repoRoot "scripts\collect-run-metrics.ps1"),
        "-RunId", "ls-e",
        "-OutDir", $collectorOutDir,
        "-IntervalSeconds", "5",
        "-DurationSeconds", "0",
        "-RabbitMqUrl", "http://localhost:$mgmt",
        "-RabbitMqUser", "flashsale",
        "-RabbitMqPassword", "flashsale_dev",
        "-RedisContainer", $redis,
        "-PostgresContainer", $Container,
        "-OrderMetricsUrl", "http://localhost:$orderPort/metrics",
        "-InventoryMetricsUrl", "http://localhost:$invPort/metrics",
        "-WorkerMetricsUrl", "http://localhost:$workerPort/metrics"
    )
    $collectorProc = Start-Process -FilePath "powershell" -ArgumentList $collectorArgs `
        -RedirectStandardOutput (Join-Path $collectorOutDir "collector.out.log") `
        -RedirectStandardError (Join-Path $collectorOutDir "collector.err.log") `
        -WindowStyle Hidden -PassThru
    Start-Sleep 3   # one sample with the broker still up (a real queue depth)

    # Stop the broker so every publish fails and the Outbox grows 1:1 with accepted orders.
    docker stop $mq | Out-Null
    $eStockBefore = Stock $pE
    $eScardBefore = Scard $pE
    # Place MaxOutboxBacklog + 5 orders one at a time. RecordAccepted arms the
    # bound on every 201, so the 6th request is refused without waiting for the
    # next Outbox poll; every 201 and 503 is recorded so nothing accepted is missed.
    $rejBacklogBefore = AdmissionRejectedBacklogTotal
    $eAccepted = @(); $eRejected = @()
    for ($i = 0; $i -lt ($eMaxBacklog + 5); $i++) {
        $key = "ls-e$i-" + [guid]::NewGuid()
        $rr = Post-Http $key $pE
        if ($rr.Status -eq 201 -and $null -ne $rr.Id) { $eAccepted += @{ Key = $key; Id = $rr.Id } }
        elseif ($rr.Status -eq 503) { $eRejected += @{ Key = $key; RetryAfter = $rr.RetryAfter } }
    }
    $rejBacklogAfter = AdmissionRejectedBacklogTotal

    $eAllRetry = $true
    foreach ($r in $eRejected) { if (-not $r.RetryAfter) { $eAllRetry = $false } }
    Check "E: some 201s then 503s with Retry-After, accepted at most MaxOutboxBacklog" ($eAccepted.Count -ge 1 -and $eRejected.Count -ge 1 -and $eAllRetry -and $eAccepted.Count -le $eMaxBacklog) "accepted=$($eAccepted.Count) rejected=$($eRejected.Count)"
    Check "E: flashsale_admission_rejected_total{reason=backlog} rose by exactly the 503 count" ($eRejected.Count -gt 0 -and ($rejBacklogAfter - $rejBacklogBefore) -eq $eRejected.Count) "before=$rejBacklogBefore after=$rejBacklogAfter 503=$($eRejected.Count)"
    $eNoRow = $true
    foreach ($r in $eRejected) { if ((OrderRowCount $r.Key) -ne 0) { $eNoRow = $false } }
    Check "E: no order/Outbox row for any 503 key; Redis stock and SCARD unchanged" ($eNoRow -and $eRejected.Count -gt 0 -and (UnpublishedRows) -eq $eAccepted.Count -and (Stock $pE) -eq "$eStockBefore" -and (Scard $pE) -eq $eScardBefore) "503-keys=$($eRejected.Count) unpublished=$(UnpublishedRows) accepted=$($eAccepted.Count)"
    $eReplayOk = $false
    if ($eAccepted.Count -gt 0) {
        $eReplay = Post-Http $eAccepted[0].Key $pE
        $eReplayOk = ($eReplay.Status -eq 200 -and $eReplay.Id -eq $eAccepted[0].Id)
    }
    Check "E: replay of an accepted key returns 200 with the original order while the backlog is full" $eReplayOk "accepted=$($eAccepted.Count)"

    # Restore the broker, then restart all three services so every connection
    # (publisher and consumers) is rebuilt against the live broker.
    docker start $mq | Out-Null
    if (-not (Wait-Until { $null -ne (Mq Get "/overview") } 90)) { throw "RabbitMQ did not come back after restart" }
    Stop-Svc "FlashSale.OrderService"
    Stop-Svc "FlashSale.InventoryService"
    Stop-Svc "FlashSale.ProcessWorker"
    Start-Svc "FlashSale.OrderService" "backlog2" @{ Admission__Enabled = "true"; Admission__MaxConcurrentNewOrders = "1000"; Admission__MaxOutboxBacklog = "$eMaxBacklog" }
    Start-Svc "FlashSale.InventoryService" "e"
    Start-Svc "FlashSale.ProcessWorker" "e"
    $eIds = @($eAccepted | ForEach-Object { $_.Id })
    $eDone = Wait-Until { AllCompleted $eIds } 120
    $eDrained = Wait-Until { (UnpublishedRows) -eq 0 -and (OutboxUnpublished) -eq 0 } 120
    Check "E: after the broker returns, the Outbox drains to 0 and every accepted order completes" ($eDone -and $eDrained) "completed=$eDone drained=$eDrained unpublished=$(UnpublishedRows)"
    Check "E: SCARD processed:<pE> = accepted and stock = initial - accepted" ((Scard $pE) -eq $eAccepted.Count -and (Stock $pE) -eq "$($pEStock - $eAccepted.Count)") "scard=$(Scard $pE) stock=$(Stock $pE) accepted=$($eAccepted.Count)"
    $eNew = Post-Http ("ls-enew-" + [guid]::NewGuid()) $pE
    Check "E: a new order is admitted again (201) once the backlog drained" ($eNew.Status -eq 201 -and $null -ne $eNew.Id) "status=$($eNew.Status)"
    if ($null -ne $eNew.Id) { Wait-Until { (State $eNew.Id) -eq "Completed" } 120 | Out-Null }

    # G. stop the collector and check its CSV.
    Set-Content -LiteralPath (Join-Path $collectorOutDir "STOP") -Value "stop" -Encoding ASCII
    $collectorProc.WaitForExit(60000) | Out-Null
    $csv = @()
    if (Test-Path -LiteralPath (Join-Path $collectorOutDir "samples.csv")) { $csv = @(Import-Csv (Join-Path $collectorOutDir "samples.csv")) }
    $gRows = @($csv).Count
    $gOutboxRise = $false; $gReasonBacklog = $false; $gQueueDepth = $false
    foreach ($row in $csv) {
        if ($row.name -eq "flashsale_outbox_unpublished" -and $row.labels -like "*service=order-service*") {
            $v = $row.value -as [double]; if ($null -ne $v -and $v -gt 0) { $gOutboxRise = $true }
        }
        if ($row.name -eq "flashsale_admission_rejected_total" -and $row.labels -like "*reason=*backlog*") {
            $v = $row.value -as [double]; if ($null -ne $v -and $v -gt 0) { $gReasonBacklog = $true }
        }
        if ($row.source -eq "rabbitmq" -and $row.name -eq "messages_ready") {
            $v = $row.value -as [double]; if ($null -ne $v) { $gQueueDepth = $true }
        }
    }
    if ($gRows -eq 0) {
        $gDetail = "collector wrote no data rows (rows=0; early exit before the first sample)"
    } else {
        $gDetail = "rows=$gRows outboxRise=$gOutboxRise reasonBacklog=$gReasonBacklog queueDepth=$gQueueDepth"
    }
    Check "G: collector CSV has outbox_unpublished > 0, reason=backlog > 0 and a RabbitMQ queue depth" ($gRows -gt 0 -and $gOutboxRise -and $gReasonBacklog -and $gQueueDepth) $gDetail

    # ---------------------------------------------------------- F. validator -Config C3
    Write-Output "== F. Validator -Config C3 (check 5) on E's product"
    $v1 = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C3 -ProductId $pE -InitialStock $pEStock -PgContainer $Container -RedisContainer $redis *>&1 | Out-String
    $v1Exit = $LASTEXITCODE
    Check "F: validator -Config C3 passes after the drain (check 5 PASS)" ($v1Exit -eq 0 -and $v1 -match '5\. accepted-order accounting\s+PASS') "exit=$v1Exit"
    # Negative fixture: stop Inventory, one last order is left PendingStock.
    Stop-Svc "FlashSale.InventoryService"
    $fKey = "ls-f-" + [guid]::NewGuid()
    $fResp = Post-Http $fKey $pE
    Check "F: negative-fixture order accepted (201) and left PendingStock (Inventory down)" ($fResp.Status -eq 201 -and $null -ne $fResp.Id) "status=$($fResp.Status)"
    $v2 = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C3 -ProductId $pE -InitialStock $pEStock -PgContainer $Container -RedisContainer $redis *>&1 | Out-String
    $v2Exit = $LASTEXITCODE
    $fListed = ($null -ne $fResp.Id -and $v2 -match [regex]::Escape($fResp.Id))
    Check "F: validator C3 with an outstanding order is INCONCLUSIVE (check 5 lists it) and exits 1" ($v2Exit -eq 1 -and $v2 -match '5\. accepted-order accounting\s+INCONCLUSIVE' -and $fListed) "exit=$v2Exit listed=$fListed"
    Start-Svc "FlashSale.InventoryService" "f"
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    docker rm -f $nginx $mq $redis *> $null
    foreach ($project in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $project }
    # R6: drop G's per-run collector folder once its CSV has been read, so
    # repeated runs do not pile up GUID-suffixed folders.
    if ($collectorOutDir -and (Test-Path -LiteralPath $collectorOutDir)) { Remove-Item -LiteralPath $collectorOutDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: the three C3 layers shed load early, the Outbox backlog is bounded, and C2 is unchanged."
exit 0
