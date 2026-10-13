# ============================================================
# M1 TP-E04 (docs/infrastructure.md): the three services run against the local
# Compose stack under their own database accounts, with named sessions, and a
# service is denied any other service's schema.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-runtime-accounts.ps1
#
# Runs against the RUNNING local Compose stack only: PostgreSQL
# (infra-postgres-1), Redis (infra-redis-1) and RabbitMQ on 5672. It never
# resets, reseeds, drops or migrates anything. The only writes it makes are the
# warm-up of one unique product id (stock 3) and three orders for it.
#
# Cases:
#   Preflight (FAIL with a pointer to docs/infrastructure.md): the Compose
#     containers are running; both service roles exist; every order_service
#     table is owned by order_service_user and every inventory_service table by
#     inventory_service_user; public tables are owned by order_service_user;
#     Inventory's migration history is in inventory_service.
#   Run exactly as documented: no ConnectionStrings__* or RabbitMQ__* env var
#     is set; the three services start with `dotnet run --project src\<Service>`
#     (checked-in settings) and reach readiness from their logs; the product is
#     warmed; 3 orders are placed through https://localhost:44314/api/orders and
#     each ends Completed.
#   Runtime accounts (pg_stat_activity, while all three services run): at least
#     one session with application_name = FlashSale.OrderService and every one
#     of them is order_service_user; the same for FlashSale.InventoryService /
#     inventory_service_user; no session names the Worker (whose appsettings.json
#     has no ConnectionStrings section); every non-verifier session belongs to
#     one of the two named apps.
#   Writes land in their own schema: the 3 orders and their Outbox rows are in
#     order_service, their stock results and Inventory Inbox rows in
#     inventory_service.
#   Cross-schema denial with the services' real credentials parsed from their
#     checked-in appsettings.json (quoted PostgreSQL error): order_service_user
#     reading inventory_service.outbox_events, inventory_service_user reading
#     order_service.orders and public."AbpUsers" are each denied; each user's
#     own-schema read succeeds.
#   ERD: scripts/verify-erd.ps1 is run against infra-postgres-1.
#
# Cleanup stops the three services it started (no orphaned processes) and leaves
# the rows (they are harmless and use this script's own product id).
# ============================================================
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
$checks = 0
$expectedChecks = 32    # number of Check calls in the try block (a truncated run must fail)

$pg = "infra-postgres-1"
$redis = "infra-redis-1"
$mq = "infra-rabbitmq-1"
$orderUrl = "https://localhost:44314/api/orders"
$orderPort = 44314; $invPort = 44379; $workerPort = 5100
$projects = @("FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker")
$logs = @{}   # project -> current log file (redirected stdout)

# One unique product id per run, so this script's rows can be told apart from
# any earlier run's (Claude's prototype left rows on the Compose stack too).
$p = "m1-rt-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

# ------------------------------------------------------------------ helpers
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    # Count BEFORE any output, and write to the output stream (not the host),
    # so a broken console can never turn a failure into a pass.
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}
# Admin queries run as flashsale over the container's unix socket (trust).
function Sql([string]$sql) {
    $out = $sql | docker exec -i $pg psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql) {
    $v = Sql $sql
    if ($v -match '^\d+$') { return [int]$v }
    return -1   # empty or an ERROR line: never let a cast throw and mask a FAIL
}
# Service-user queries run over TCP with the parsed password (scram-sha-256),
# exactly as the services themselves authenticate (verify-environment.ps1).
function Invoke-Psql([string]$user, [string]$password, [string]$sql) {
    $out = $sql | docker exec -i -e "PGPASSWORD=$password" $pg psql -h localhost -U $user -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out | Out-String).Trim() }
}
function Log([string]$project) {
    if (-not $logs[$project]) { return "" }
    if (-not (Test-Path -LiteralPath $logs[$project])) { return "" }
    $fs = New-Object IO.FileStream($logs[$project], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Running([string]$project) { return @(Get-CimInstance Win32_Process -Filter "Name='$project.exe'").Count -gt 0 }
function Stop-Svc([string]$project) {
    Get-CimInstance Win32_Process -Filter "Name='$project.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Wait-Until { -not (Running $project) } 20 | Out-Null
}
# Start with the checked-in settings and the launch profile: `dotnet run
# --project src\<Service>`. No environment overrides are set, so the services
# listen where their own appsettings/launchSettings say (Order 44314, Inventory
# 44379, Worker 5100) and use their own connection strings.
function Start-Svc([string]$project) {
    $log = Join-Path $env:TEMP "verify-rt-$project.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--project", "src\$project" `
        -WorkingDirectory $repoRoot -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 180 | Out-Null
}
# Parses a Npgsql connection string into a hashtable (keys keep their spaces:
# "Application Name", "Maximum Pool Size", "Search Path").
function Parse-ConnString([string]$cs) {
    $map = @{}
    foreach ($part in ($cs -split ';')) {
        if ($part -notmatch '=') { continue }
        $k, $v = $part -split '=', 2
        $map[$k.Trim()] = $v.Trim()
    }
    return $map
}
function State([string]$id) { return (Sql "SELECT `"State`" FROM order_service.orders WHERE `"Id`" = '$id';") }
function AllCompleted([string[]]$ids) { foreach ($id in $ids) { if ((State $id) -ne "Completed") { return $false } }; return $true }
function Post-Order([string]$product) {
    $key = "m1-rt-" + [guid]::NewGuid().ToString("N")
    $corr = "m1-rt-" + [guid]::NewGuid().ToString("N")
    $bodyFile = Join-Path $env:TEMP "verify-rt-body-$([guid]::NewGuid().ToString('N')).json"
    # Body goes to a file and is read back with --data-binary @file: Windows
    # PowerShell 5.1 strips embedded double quotes from native arguments, so the
    # JSON must not be passed on the command line.
    ('{"productId":"' + $product + '","quantity":1}') | Set-Content $bodyFile -Encoding ASCII
    try {
        $resp = & curl.exe -s -k -X POST $orderUrl `
            -H "Content-Type: application/json" -H "Idempotency-Key: $key" -H "X-Correlation-Id: $corr" `
            --data-binary "@$bodyFile" 2>&1
        $text = ($resp | Out-String).Trim()
        $obj = $text | ConvertFrom-Json
        return "$($obj.id)"
    } catch { return "" } finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

# ================================================================== run
try {
    # ---------------------------------------------------------- preflight
    Write-Output "== Preflight (see docs/infrastructure.md if any of these fail)"
    function DockerRunning([string]$name) { return ((docker inspect -f '{{.State.Running}}' $name 2>$null | Out-String).Trim() -eq "true") }
    $pgUp = DockerRunning $pg; $redisUp = DockerRunning $redis; $mqUp = DockerRunning $mq
    Check "Compose containers are running ($pg, $redis, $mq)" ($pgUp -and $redisUp -and $mqUp) "postgres=$pgUp redis=$redisUp rabbitmq=$mqUp (see docs/infrastructure.md)"
    $roles = Sql "SELECT count(*) FROM pg_roles WHERE rolname IN ('order_service_user','inventory_service_user')"
    Check "both service roles exist" ($roles -eq "2") "roles=$roles (see docs/infrastructure.md)"
    $ordBad = Sql "SELECT count(*) FROM pg_tables WHERE schemaname = 'order_service' AND tableowner <> 'order_service_user'"
    Check "every order_service table is owned by order_service_user" ($ordBad -eq "0") "not-owned=$ordBad (see docs/infrastructure.md)"
    $invBad = Sql "SELECT count(*) FROM pg_tables WHERE schemaname = 'inventory_service' AND tableowner <> 'inventory_service_user'"
    Check "every inventory_service table is owned by inventory_service_user" ($invBad -eq "0") "not-owned=$invBad (see docs/infrastructure.md)"
    $pubBad = Sql "SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tableowner <> 'order_service_user'"
    Check "public tables are owned by order_service_user" ($pubBad -eq "0") "not-owned=$pubBad (see docs/infrastructure.md)"
    $invHist = Sql "SELECT count(*) FROM inventory_service.""__EFMigrationsHistory"""
    Check "Inventory migration history is in inventory_service" ($invHist -match '^\d+$' -and [int]$invHist -gt 0) "rows=$invHist (see docs/infrastructure.md)"

    if ($failures -gt 0) {
        Write-Output "FAIL  preflight failed; set up the local stack as described in docs/infrastructure.md"
    } else {

    # ---------------------------------------------------------- run exactly as documented
    Write-Output "== Checked-in settings (no environment overrides)"
    $connEnv = @(Get-ChildItem Env: | Where-Object { $_.Name -like "ConnectionStrings__*" })
    Check "no ConnectionStrings__* environment variable is set" ($connEnv.Count -eq 0) ($connEnv.Name -join ",")
    $mqEnv = @(Get-ChildItem Env: | Where-Object { $_.Name -like "RabbitMQ__*" })
    Check "no RabbitMQ__* environment variable is set" ($mqEnv.Count -eq 0) ($mqEnv.Name -join ",")

    foreach ($port in $orderPort, $invPort, $workerPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use; stop any running service first" }
    }

    Start-Svc "FlashSale.OrderService"
    Start-Svc "FlashSale.InventoryService"
    Start-Svc "FlashSale.ProcessWorker"
    Check "Order Service reached readiness (Consuming)" ((Log "FlashSale.OrderService") -match "Consuming")
    Check "Inventory Service reached readiness (Consuming)" ((Log "FlashSale.InventoryService") -match "Consuming")
    Check "Process Worker reached readiness (Consuming)" ((Log "FlashSale.ProcessWorker") -match "Consuming")

    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p = 3 } -Force *> $null
    $stock = (docker exec $redis redis-cli GET "inventory:$p" 2>&1 | Out-String).Trim()
    Check "warm-up: $p has 3 units" ($stock -eq "3") "stock=$stock"

    # Baseline inbox counts, so the schema-placement check below is scoped to
    # this run's three orders even though earlier runs left rows on this stack.
    $invInboxBefore = Int1 "SELECT count(*) FROM inventory_service.processed_messages"
    $orderInboxBefore = Int1 "SELECT count(*) FROM order_service.processed_messages"

    Write-Output "== Place 3 orders through $orderUrl"
    $ids = @()
    for ($i = 0; $i -lt 3; $i++) {
        $id = Post-Order $p
        if ($id) { $ids += $id }
    }
    Check "3 orders accepted through the API" ($ids.Count -eq 3) "orders=$($ids.Count)"
    $done = Wait-Until { (AllCompleted $ids) } 90
    Check "each order ends Completed" $done (($ids | ForEach-Object { "$_=$(State $_)" }) -join ",")
    $idsCsv = (($ids | ForEach-Object { "'$_'" }) -join ",")

    # ---------------------------------------------------------- runtime accounts
    Write-Output "== Runtime accounts (pg_stat_activity, all three services running)"
    $ordSessions = Int1 "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'FlashSale.OrderService'"
    Check "at least one session has application_name = FlashSale.OrderService" ($ordSessions -ge 1) "sessions=$ordSessions"
    $ordWrong = Int1 "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'FlashSale.OrderService' AND usename <> 'order_service_user'"
    Check "every FlashSale.OrderService session is order_service_user" ($ordWrong -eq 0) "wrong=$ordWrong"
    $invSessions = Int1 "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'FlashSale.InventoryService'"
    Check "at least one session has application_name = FlashSale.InventoryService" ($invSessions -ge 1) "sessions=$invSessions"
    $invWrong = Int1 "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'FlashSale.InventoryService' AND usename <> 'inventory_service_user'"
    Check "every FlashSale.InventoryService session is inventory_service_user" ($invWrong -eq 0) "wrong=$invWrong"
    $workerNamed = Int1 "SELECT count(*) FROM pg_stat_activity WHERE application_name ILIKE '%ProcessWorker%'"
    Check "no session names the Process Worker" ($workerNamed -eq 0) "worker-named=$workerNamed"
    # Every session that is not the verifier's own admin (flashsale) session, and
    # not a system backend (usename IS NULL), must be one of the two named apps.
    $stray = Int1 "SELECT count(*) FROM pg_stat_activity WHERE usename IS NOT NULL AND usename <> 'flashsale' AND application_name NOT IN ('FlashSale.OrderService','FlashSale.InventoryService')"
    Check "every non-verifier session belongs to one of the two named apps" ($stray -eq 0) "stray=$stray"
    $workerApp = Get-Content -Raw (Join-Path $repoRoot "src\FlashSale.ProcessWorker\appsettings.json") -Encoding UTF8 | ConvertFrom-Json
    Check "Process Worker appsettings.json has no ConnectionStrings section" ($null -eq $workerApp.ConnectionStrings) "worker has no database"

    # ---------------------------------------------------------- writes land in own schema
    Write-Output "== Each service's writes land in its own schema"
    $orders = Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$p'"
    Check "the 3 orders are in order_service.orders" ($orders -eq 3) "rows=$orders"
    $orderOutbox = Int1 "SELECT count(*) FROM order_service.outbox_events WHERE `"OrderId`" IN ($idsCsv)"
    Check "their OrderPlaced Outbox rows are in order_service.outbox_events" ($orderOutbox -eq 3) "rows=$orderOutbox"
    $invOutbox = Int1 "SELECT count(*) FROM inventory_service.outbox_events WHERE `"OrderId`" IN ($idsCsv)"
    Check "their stock results are in inventory_service.outbox_events" ($invOutbox -eq 3) "rows=$invOutbox"
    $invInbox = Int1 "SELECT count(*) FROM inventory_service.processed_messages"
    $invInboxDelta = $invInbox - $invInboxBefore
    Check "Inventory Inbox grew by 3 (one OrderPlaced per order)" ($invInboxDelta -eq 3) "delta=$invInboxDelta"
    $orderInbox = Int1 "SELECT count(*) FROM order_service.processed_messages"
    $orderInboxDelta = $orderInbox - $orderInboxBefore
    Check "Order Inbox rows landed in order_service.processed_messages" ($orderInboxDelta -ge 3) "delta=$orderInboxDelta"

    # ---------------------------------------------------------- cross-schema denial
    Write-Output "== Cross-schema denial (credentials parsed from checked-in appsettings.json)"
    $orderCs = (Get-Content -Raw (Join-Path $repoRoot "src\FlashSale.OrderService\appsettings.json") -Encoding UTF8 | ConvertFrom-Json).ConnectionStrings.Default
    $invCs = (Get-Content -Raw (Join-Path $repoRoot "src\FlashSale.InventoryService\appsettings.json") -Encoding UTF8 | ConvertFrom-Json).ConnectionStrings.Default
    $orderConn = Parse-ConnString $orderCs
    $invConn = Parse-ConnString $invCs
    $cross = @(
        @{ U = $orderConn["Username"]; P = $orderConn["Password"]; Sql = "SELECT count(*) FROM inventory_service.outbox_events"; Allowed = $false; Label = "order_service_user reading inventory_service.outbox_events is denied" }
        @{ U = $invConn["Username"]; P = $invConn["Password"]; Sql = "SELECT count(*) FROM order_service.orders"; Allowed = $false; Label = "inventory_service_user reading order_service.orders is denied" }
        @{ U = $invConn["Username"]; P = $invConn["Password"]; Sql = "SELECT count(*) FROM public.""AbpUsers"""; Allowed = $false; Label = "inventory_service_user reading public.""AbpUsers"" is denied" }
        @{ U = $orderConn["Username"]; P = $orderConn["Password"]; Sql = "SELECT count(*) FROM order_service.orders"; Allowed = $true; Label = "order_service_user reads its own schema (order_service.orders)" }
        @{ U = $invConn["Username"]; P = $invConn["Password"]; Sql = "SELECT count(*) FROM inventory_service.outbox_events"; Allowed = $true; Label = "inventory_service_user reads its own schema (inventory_service.outbox_events)" }
    )
    foreach ($c in $cross) {
        $r = Invoke-Psql $c.U $c.P $c.Sql
        $ok = if ($c.Allowed) { $r.Ok } else { (-not $r.Ok) -and ($r.Output -match "permission denied") }
        Check $c.Label $ok ($(if ($c.Allowed) { "exit=$($r.Ok)" } else { "postgres: $($r.Output)" }))
    }

    # ---------------------------------------------------------- ERD
    Write-Output "== ERD still matches the real database"
    powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\verify-erd.ps1") -Container $pg
    $erdExit = $LASTEXITCODE
    Check "scripts/verify-erd.ps1 passes against infra-postgres-1" ($erdExit -eq 0) "exit=$erdExit"
    }
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    foreach ($proj in $projects) { Stop-Svc $proj }
}
Write-Output ""
if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "The application runs under its own accounts, names its sessions, writes only to its own schema, and cross-schema access is denied."
