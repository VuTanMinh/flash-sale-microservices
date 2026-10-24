# ============================================================
# Pilot: C1 (synchronous PostgreSQL conditional UPDATE) and C2 (Redis Lua +
# RabbitMQ + Outbox/Inbox, no load-shedding limits) offered the SAME steady
# load, one after the other, on the same processes and database.
#
#   powershell -File .\scripts\run-pilot-c1-c2.ps1 -Container verify-env-pg -DbPort 55432 -Rate 50 -Duration 60
#
# A preliminary point for the research question, not an official run: one
# load level, one run each, one machine (load generator and system share it).
#
# Runs Order Service, Inventory Service and the Process Worker on a throwaway
# RabbitMQ (5710/15710) and Redis (6420) against the given PostgreSQL container
# (which must have the baseline schema, e.g. from verify-environment.ps1).
# Each configuration gets its own product with enough stock that every request
# can succeed (demand below stock), so both are measured on successful work.
# The Worker runs with -WorkerConcurrency handlers (declared in the output);
# its fixed delay stays the default 200 ms.
#
# Per configuration:
#   - offered vs achieved request rate, response codes, response-time
#     p50/p95/p99 from the JTL (POST submissions only);
#   - C1: every response is the stock decision, so decision latency = response
#     time; decisions/s from the baseline_orders rows;
#   - C2: response = acceptance (201); accepted->decided and accepted->completed
#     per order from scripts/extract-run-metrics.ps1 (run membership by the
#     JTL's Idempotency-Keys); decisions/s from the decision timestamps;
#   - scripts/validate-correctness.ps1 for the configuration (C1 or C2).
# Writes everything under -OutDir and prints a summary; exits 1 if a run had
# non-2xx responses, a validator failure, or C2 orders still unfinished.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$DbPort = 55432,
    [int]$Rate = 50,
    [int]$Duration = 60,
    [int]$WorkerConcurrency = 32,
    [int]$Stock = 100000,
    [string]$JMeterBat = "D:\tools\apache-jmeter-5.6.3\bin\jmeter.bat",
    [string]$OutDir = ""
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
if ($OutDir -eq "") { $OutDir = Join-Path $env:TEMP "pilot-c1-c2-$stamp" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$inv = [Globalization.CultureInfo]::InvariantCulture

$mq = "pilot-mq"; $amqp = 5710; $mgmt = 15710; $redis = "pilot-redis"; $redisPort = 6420
$orderPort = 5170; $invPort = 5171; $workerPort = 5172
$ex = "flashsale.order.exchange"; $dlx = "flashsale.dlx"
$pg = "Host=localhost;Port=$DbPort;Database=flashsale"
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$svcEnv = @{
    "FlashSale.OrderService" = @{ ConnectionStrings__Default = "$pg;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"; ASPNETCORE_URLS = "http://localhost:$orderPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Reconciliation__Enabled = "false" }
    "FlashSale.InventoryService" = @{ ConnectionStrings__Default = "$pg;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service;Maximum Pool Size=30"; ASPNETCORE_URLS = "http://localhost:$invPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Redis__Configuration = "localhost:$redisPort" }
    "FlashSale.ProcessWorker" = @{ Urls = "http://localhost:$workerPort"; RabbitMQ__Connections__Default__Port = "$amqp"; Processing__MaxConcurrency = "$WorkerConcurrency" }
}
$logs = @{}
$problems = New-Object System.Collections.Generic.List[string]

function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL failed: $out" }
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Mq([string]$method, [string]$path) {
    try { return Invoke-RestMethod -Method $method -Headers $auth -Uri "http://localhost:$mgmt/api$path" -TimeoutSec 10 } catch { return $null }
}
function Wait-Until([scriptblock]$cond, [int]$seconds = 30) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Log([string]$project) {
    if (-not $logs[$project] -or -not (Test-Path -LiteralPath $logs[$project])) { return "" }
    $fs = New-Object IO.FileStream($logs[$project], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Stop-Svc([string]$project) {
    Get-CimInstance Win32_Process -Filter "Name='$project.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Start-Svc([string]$project) {
    $envs = @{} + $svcEnv[$project]
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $envs[$k] }
    $log = Join-Path $OutDir "$project.log"
    Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" -WorkingDirectory (Join-Path $repoRoot "src\$project") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden | Out-Null
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" -Value $null }
    $script:logs[$project] = $log
    Wait-Until { (Test-Path $log) -and (Log $project) -match "Consuming" } 120 | Out-Null
}
function Rank([double[]]$sorted, [double]$p) {
    if ($sorted.Count -eq 0) { return $null }
    $r = [int][math]::Ceiling($p / 100.0 * $sorted.Count); if ($r -lt 1) { $r = 1 }; if ($r -gt $sorted.Count) { $r = $sorted.Count }
    return $sorted[$r - 1]
}
function Pct([double[]]$values) {
    $s = @($values | Sort-Object)
    return [ordered]@{ n = $s.Count; p50 = (Rank $s 50); p95 = (Rank $s 95); p99 = (Rank $s 99); max = $(if ($s.Count) { $s[-1] } else { $null }) }
}
function Run-JMeter([string]$path, [string]$product, [string]$jtl) {
    & $JMeterBat -n -t (Join-Path $repoRoot "tests\jmeter\pilot-steady.jmx") `
        "-Jhost=localhost" "-Jport=$orderPort" "-Jpath=$path" "-Jproduct=$product" `
        "-Jrate=$Rate" "-Jduration=$Duration" "-Jsample_variables=idempotencyKey" `
        -l $jtl -j "$jtl.jmeter.log" 2>&1 | Select-String "summary =" | Select-Object -Last 1 | ForEach-Object { Write-Output "  jmeter: $($_.Line.Trim())" }
}
function Jtl-Summary([string]$jtl) {
    $rows = @(Import-Csv -LiteralPath $jtl | Where-Object { $_.label -like "submit*" })
    $ts = @($rows | ForEach-Object { [long]$_.timeStamp } | Sort-Object)
    $span = $(if ($ts.Count -gt 1) { ($ts[-1] - $ts[0]) / 1000.0 } else { 0 })
    $codes = [ordered]@{}; foreach ($g in ($rows | Group-Object responseCode | Sort-Object Name)) { $codes[$g.Name] = $g.Count }
    $ok = @($rows | Where-Object { $_.responseCode -match '^2\d\d$' } | ForEach-Object { [double]$_.elapsed })
    return [ordered]@{
        submissions = $rows.Count; span_s = [math]::Round($span, 1)
        achieved_rate_per_s = $(if ($span -gt 0) { [math]::Round($rows.Count / $span, 1) } else { $null })
        codes = $codes; response_ms_2xx = (Pct $ok)
    }
}

$summary = [ordered]@{ stamp = $stamp; offered_rate_per_s = $Rate; duration_s = $Duration; worker_concurrency = $WorkerConcurrency; stock = $Stock; git_commit = (git -C $repoRoot rev-parse HEAD) }
try {
    Write-Output "== Stack (throwaway RabbitMQ and Redis, database $Container)"
    foreach ($c in $mq, $redis) { docker rm -f $c *> $null }
    foreach ($p in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $p }
    docker run -d --name $redis -p "${redisPort}:6379" redis:7 | Out-Null
    $defs = Join-Path $OutDir "rabbit-definitions.json"; $conf = Join-Path $OutDir "rabbit.conf"
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
    foreach ($p in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Start-Svc $p }
    if (-not (Wait-Until { $null -ne (Mq Get "/queues/%2F/ProcessWorker.StockReserved") -and $null -ne (Mq Get "/queues/%2F/OrderPlaced") } 120)) { throw "services did not declare their queues" }
    Write-Output "  services up; Worker: $(([regex]::Match((Log 'FlashSale.ProcessWorker'), '\d+ at a time')).Value)"

    # ------------------------------------------------------------------ C1
    Write-Output "== C1: POST /api/c1/orders at $Rate r/s for $Duration s"
    $p1 = "pilot-c1-$stamp"
    Sql "INSERT INTO order_service.inventory (product_id, stock) VALUES ('$p1', $Stock);" | Out-Null
    $jtl1 = Join-Path $OutDir "c1.jtl"
    Run-JMeter "/api/c1/orders" $p1 $jtl1
    $c1 = Jtl-Summary $jtl1
    $c1Rows = Sql "SELECT count(*) || '|' || count(*) FILTER (WHERE result = 'Confirmed') || '|' || coalesce(extract(epoch from (max(created_at) - min(created_at)))::text, '0') FROM order_service.baseline_orders WHERE config = 'C1' AND product_id = '$p1';"
    $parts = $c1Rows -split '\|'
    $c1.decisions = [int]$parts[0]; $c1.confirmed = [int]$parts[1]
    $c1.decisions_per_s = $(if ([double]$parts[2] -gt 0) { [math]::Round([int]$parts[0] / [double]$parts[2], 1) } else { $null })
    $c1.decision_ms = "= response time (synchronous)"
    $c1.validator = (& powershell -NoProfile -File (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C1 -ProductId $p1 -InitialStock $Stock -PgContainer $Container 2>&1 | Out-String)
    $c1.validator_exit = $LASTEXITCODE
    $summary.C1 = $c1

    # ------------------------------------------------------------------ C2
    Write-Output "== C2: POST /api/orders at $Rate r/s for $Duration s (no C3 limits)"
    $p2 = "pilot-c2-$stamp"
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $p2 = $Stock } -Force *> $null
    $jtl2 = Join-Path $OutDir "c2.jtl"
    Run-JMeter "/api/orders" $p2 $jtl2
    $c2 = Jtl-Summary $jtl2
    $drained = Wait-Until { [int](Sql "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$p2' AND `"State`" NOT IN ('Completed','Rejected');") -eq 0 } 300
    $c2.all_finished = $drained
    $runDir = Join-Path $OutDir "c2-extract"; New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $extractOut = & powershell -NoProfile -File (Join-Path $repoRoot "scripts\extract-run-metrics.ps1") -RunId "pilot-c2-$stamp" -RunDir $runDir -JtlPath $jtl2 -Container $Container 2>&1 | Out-String
    $c2.extract_exit = $LASTEXITCODE
    $s2 = Get-Content (Join-Path $runDir "summary.json") -Raw | ConvertFrom-Json
    $c2.accepted = $s2.database.accepted_count; $c2.completed = $s2.database.completed_count; $c2.membership = $s2.database.run_membership
    $iv = @(Import-Csv (Join-Path $runDir "stage-intervals.csv"))
    $dec = @(foreach ($r in $iv) { if ($r.accepted_to_published_ms -ne "" -and $r.published_to_decided_ms -ne "") { [double]::Parse($r.accepted_to_published_ms, $inv) + [double]::Parse($r.published_to_decided_ms, $inv) } })
    $comp = @(foreach ($r in $iv) { if ($r.accepted_to_completed_ms -ne "") { [double]::Parse($r.accepted_to_completed_ms, $inv) } })
    $c2.accepted_to_decided_ms = (Pct $dec); $c2.accepted_to_completed_ms = (Pct $comp)
    $span2 = Sql "SELECT count(*) || '|' || coalesce(extract(epoch from (max(`"ConfirmedOrRejectedAt`") - min(`"RequestAcceptedAt`")))::text, '0') FROM order_service.orders WHERE `"ProductId`" = '$p2' AND `"ConfirmedOrRejectedAt`" IS NOT NULL;"
    $q = $span2 -split '\|'
    $c2.decisions = [int]$q[0]
    $c2.decisions_per_s = $(if ([double]$q[1] -gt 0) { [math]::Round([int]$q[0] / [double]$q[1], 1) } else { $null })
    $c2.validator = (& powershell -NoProfile -File (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C2 -ProductId $p2 -InitialStock $Stock -PgContainer $Container -RedisContainer $redis 2>&1 | Out-String)
    $c2.validator_exit = $LASTEXITCODE
    $summary.C2 = $c2

    foreach ($n in "C1", "C2") {
        $r = $summary[$n]
        if (@($r.codes.Keys | Where-Object { $_ -notmatch '^2\d\d$' }).Count -gt 0) { $problems.Add("$n had non-2xx responses") }
        if ($r.validator_exit -ne 0) { $problems.Add("$n validator exit $($r.validator_exit)") }
    }
    if (-not $summary.C2.all_finished) { $problems.Add("C2 orders still unfinished after 300 s") }
}
catch { $problems.Add("unexpected error: $($_.Exception.Message)") }
finally {
    foreach ($p in "FlashSale.OrderService", "FlashSale.InventoryService", "FlashSale.ProcessWorker") { Stop-Svc $p }
    docker rm -f $mq $redis *> $null
}

$summary.problems = @($problems)
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutDir "pilot-summary.json") -Encoding UTF8
Write-Output ""
foreach ($n in "C1", "C2") {
    $r = $summary[$n]; if ($null -eq $r) { continue }
    Write-Output ("{0}: offered {1}/s, achieved {2}/s over {3} s, {4} submissions, codes {5}" -f $n, $Rate, $r.achieved_rate_per_s, $r.span_s, $r.submissions, (($r.codes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    Write-Output ("    response 2xx ms p50/p95/p99 = {0}/{1}/{2}; decisions {3} at {4}/s; validator exit {5}" -f $r.response_ms_2xx.p50, $r.response_ms_2xx.p95, $r.response_ms_2xx.p99, $r.decisions, $r.decisions_per_s, $r.validator_exit)
    if ($n -eq "C2") {
        Write-Output ("    accepted {0}, completed {1} ({2}); accepted->decided ms p50/p95/p99 = {3}/{4}/{5}; accepted->completed ms p50/p95/p99 = {6}/{7}/{8}" -f $r.accepted, $r.completed, $r.membership, $r.accepted_to_decided_ms.p50, $r.accepted_to_decided_ms.p95, $r.accepted_to_decided_ms.p99, $r.accepted_to_completed_ms.p50, $r.accepted_to_completed_ms.p95, $r.accepted_to_completed_ms.p99)
    }
}
Write-Output "output: $OutDir"
if ($problems.Count -gt 0) { Write-Output ("PROBLEMS: " + ($problems -join "; ")); exit 1 }
Write-Output "Pilot finished without problems."
