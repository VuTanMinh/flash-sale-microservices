# ============================================================
# Week 13 (TP-L06/TP-L07/TP-L08/TP-X04): the EC2 Compose stack, exercised
# locally in its own Compose project so the Week 13 pilot (C1 gateway, C4
# replicas, RabbitMQ rates, workload profiles) is checked before the live EC2
# run. Runs against infra/docker-compose.ec2.yml, never the default `infra`
# project.
#
#   powershell -File .\scripts\verify-ec2-stack.ps1
#   powershell -File .\scripts\verify-ec2-stack.ps1 -Cases A,B,D
#
# Own Compose project `-p flashsale-ec2v` (containers named
# flashsale-ec2v-<service>-<n>). It writes its own git-ignored env file
# (infra/ec2-verify.env), creates infra/openiddict.pfx if missing, sets
# NGINX_HOST_PORT=18080 and publishes rabbitmq 15692 on host 15792 via an
# override file in TEMP, so the collector's -RabbitMqMetricsUrl works on
# Docker Desktop. `docker compose down -v` for that project runs in finally.
#
# Cases (selectable with -Cases):
#   A  build + up; all services healthy; the 5 Prometheus targets (order,
#      inventory, process-worker, rabbitmq, prometheus) are up; every running
#      container logs json-file capped at 50m.
#   B  C1 through the gateway: POST /api/c1/orders via Nginx on 18080 returns
#      200 with a Result; POST /api/orders still 201; a random path is 404; a
#      burst above ORDER_RATE returns 429 on both order paths.
#   C  replicas 1, 2, 4: reset + seed + warm-up, scale, a short workload.jmx
#      load (~30 s, 50/s), drain, validator -Config C4 passes, no "too many
#      clients"/pool timeout in postgres/order/replica logs, the pg_stat_activity
#      peak stays below max_connections, every replica consumed >= 1 message this
#      run (docker logs --since the load), the DB order count equals the 2xx
#      submits, Prometheus reports N inventory targets.
#   D  collector with -RabbitMqMetricsUrl during a load: rate rows numeric and
#      > 0 at some sample, first sample "unavailable".
#   E  each workload profile: steady / ramp / spike / hot (every submission is
#      2xx and the DB order count equals the 2xx submits), overload+recovery
#      against a low gateway rate (stage 2 gets 429s, stage 3 is 2xx, drains and
#      validates), skewed across four products (each has >=1 order,
#      flash-product-1 largest), the c1 baseline (/api/c1/orders, no poll rows),
#      and below/equal/above inventory (exact volume = 5 x N/5 = N,
#      reservations = min(requests, stock)).
#
#   F  open-loop mode (-Jmode=open): C1 and C2 at requested 10/s and 50/s for 20 s.
#      achieved submissions/s from the JTL >= 90 % of requested, no poll rows, every
#      submission 2xx, and after the drain the validator passes (C2: the database
#      also holds one order per 2xx submission).
#
#   G  run-matrix.ps1 and the queue-bound gate (TP-X06): -ExpectMaxLength and
#      validator check 6 fail while the C3 policy is on the broker; a C3 then C2
#      matrix (5/s for 10 s, -Jmode=open) passes, each manifest reads back the
#      right bound, admission and gateway from the running stack, and the policy
#      is gone from the broker afterwards.
#
# This verifier needs Docker Desktop and JMeter; if either is missing it fails
# SETUP ERROR (do not weaken a check to get a pass).
# ============================================================
param(
    [ValidateSet("A", "B", "C", "D", "E", "F", "G")][string[]]$Cases = @("A", "B", "C", "D", "E", "F", "G")
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$project = "flashsale-ec2v"
$composeFile = Join-Path $repoRoot "infra\docker-compose.ec2.yml"
$envFile = Join-Path $repoRoot "infra\ec2-verify.env"
$overrideFile = Join-Path $env:TEMP "flashsale-ec2v-override.yml"
$nginxHostPort = 18080
$rabbitPromHostPort = 15792
$failures = 0
$checks = 0
$caseChecks = @{ A = 3; B = 4; C = 18; D = 3; E = 30; F = 16; G = 13 }
$expectedChecks = 0
foreach ($c in $Cases) { $expectedChecks += $caseChecks[$c] }

$pg = "$project-postgres-1"; $redis = "$project-redis-1"; $rabbit = "$project-rabbitmq-1"
$nginx = "$project-nginx-1"; $prom = "$project-prometheus-1"
$jmeterBat = "D:\tools\apache-jmeter-5.6.3\bin\jmeter.bat"
$jmx = Join-Path $repoRoot "tests\jmeter\workload.jmx"
$workProduct = "flash-product-1"

# ------------------------------------------------------------------ helpers
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}
function Compose([string[]]$composeArgs) {
    & docker compose -p $project --env-file $envFile -f $composeFile -f $overrideFile @composeArgs 2>&1
    return $LASTEXITCODE
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $pg psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql) {
    $v = Sql $sql
    if ($v -eq "" -or $v -notmatch '^-?\d+$') { return -1 }
    return [int]$v
}
function Wait-Until([scriptblock]$cond, [int]$seconds = 60) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return (& $cond) }
function Redis-Cmd([string[]]$cmd) { return (docker exec $redis redis-cli @cmd 2>&1 | Out-String).Trim() }
function Scard([string]$p) { return [int](Redis-Cmd @("SCARD", "processed:$p")) }
# Container names of a scaled service, e.g. inventory-service -> @("flashsale-ec2v-inventory-service-1", "-2", ...).
function Service-Containers([string]$service) {
    $ids = @(docker compose -p $project -f $composeFile -f $overrideFile ps -q $service 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $names = @()
    foreach ($id in $ids) {
        $n = (docker inspect -f '{{.Name}}' $id 2>$null | Out-String).Trim().TrimStart('/')
        if ($n) { $names += $n }
    }
    return @($names)
}
function Prom-Targets {
    $raw = (docker exec $prom wget -qO- http://localhost:9090/api/v1/targets 2>$null | Out-String)
    if (-not $raw) { return @() }
    try { $j = $raw | ConvertFrom-Json; return @($j.data.activeTargets | ForEach-Object { $_ }) } catch { return @() }
}
# Write the git-ignored env file with a configurable gateway rate (case B uses a
# low rate to trigger 429s; every other case uses a high rate).
function Write-EnvFile([string]$orderRate, [string]$orderBurst) {
    @"
POSTGRES_PASSWORD=flashsale_dev
RABBITMQ_PASSWORD=flashsale_dev
ORDER_SERVICE_PASSWORD=order_service_dev
INVENTORY_SERVICE_PASSWORD=inventory_service_dev
ADMISSION_ENABLED=false
ADMISSION_MAX_CONCURRENT_NEW_ORDERS=1000
ADMISSION_MAX_OUTBOX_BACKLOG=0
ADMISSION_MAX_IN_FLIGHT_ORDERS=0
PROCESSING_MAX_CONCURRENCY=1
ORDER_RATE=$orderRate
ORDER_BURST=$orderBurst
NGINX_HOST_PORT=$nginxHostPort
PG_MAX_CONNECTIONS=200
"@ | Set-Content -LiteralPath $envFile -Encoding ASCII
}
function Post-Nginx([string]$path, [string]$product) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
            -Headers @{ "Idempotency-Key" = "ec2v-" + [guid]::NewGuid() } `
            -Body ('{"productId":"' + $product + '","quantity":1}') "http://localhost:$nginxHostPort$path" -TimeoutSec 15
        return @{ Status = [int]$r.StatusCode; Body = $r.Content }
    } catch {
        $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ Status = $code; Body = "" }
    }
}
# Reset + seed + warm-up one product to `stock` units, with a full C2/C3/C4 reset.
function Reset-Seed-Warm([string]$product, [int]$stock) {
    & (Join-Path $repoRoot "scripts\reset-and-seed.ps1") -Container $pg -Full -RedisContainer $redis -RabbitMqContainer $rabbit -Products @{ $product = $stock } *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products @{ $product = $stock } -Force *> $null
    return ($LASTEXITCODE -eq 0)
}
function Run-Jmeter([string]$profile, [string[]]$extra, [string]$jtl, [string]$path = "/api/orders") {
    Remove-Item -LiteralPath $jtl -Force -ErrorAction SilentlyContinue # JMeter appends to an existing JTL
    $jmArgs = @("-n", "-t", $jmx, "-Jhost=localhost", "-Jport=$nginxHostPort", "-Jpath=$path", "-Jsample_variables=idempotencyKey")
    $jmArgs += $extra
    $jmArgs += @("-l", $jtl, "-j", ($jtl -replace '\.jtl$', '.log'))
    & $jmeterBat @jmArgs *> ($jtl -replace '\.jtl$', '-console.log')
    return $LASTEXITCODE
}
# Number of submissions in a JTL whose responseCode is NOT 2xx. For the clean
# profiles (steady/ramp/spike/hot/skewed/c1) EVERY submission must be 2xx, so a
# 404, a 429, a connection error (0) or "Non HTTP response code: ..." is a
# failure, never "clean". Returns -1 when the JTL has no submit rows.
function Jtl-Non2xxCount([string]$jtl) {
    if (-not (Test-Path -LiteralPath $jtl)) { return -1 }
    $rows = @(Import-Csv -LiteralPath $jtl)
    $subs = @($rows | Where-Object { [string]$_.label -match "submit" })
    if ($subs.Count -eq 0) { return -1 }
    $err = 0
    foreach ($r in $subs) {
        $code = [string]$r.responseCode
        if ($code -notmatch '^2\d\d$') { $err++ }
    }
    return $err
}
function Jtl-2xxSubmitCount([string]$jtl) {
    if (-not (Test-Path -LiteralPath $jtl)) { return -1 }
    return @(Import-Csv -LiteralPath $jtl | Where-Object { [string]$_.label -match 'submit' -and [string]$_.responseCode -match '^2\d\d$' }).Count
}
function Jtl-SubmitCount([string]$jtl) {
    if (-not (Test-Path -LiteralPath $jtl)) { return -1 }
    return @(Import-Csv -LiteralPath $jtl | Where-Object { [string]$_.label -match 'submit' }).Count
}
function Jtl-PollCount([string]$jtl) {
    if (-not (Test-Path -LiteralPath $jtl)) { return -1 }
    return @(Import-Csv -LiteralPath $jtl | Where-Object { [string]$_.label -match 'poll' }).Count
}
function Jtl-Stage429Count([string]$jtl, [int]$stage) {
    if (-not (Test-Path -LiteralPath $jtl)) { return -1 }
    return @(Import-Csv -LiteralPath $jtl | Where-Object { [string]$_.label -eq "submit-stage$stage" -and [string]$_.responseCode -eq "429" }).Count
}
function Jtl-StageNon2xxCount([string]$jtl, [int]$stage) {
    if (-not (Test-Path -LiteralPath $jtl)) { return -1 }
    return @(Import-Csv -LiteralPath $jtl | Where-Object { [string]$_.label -eq "submit-stage$stage" -and [string]$_.responseCode -notmatch '^2\d\d$' }).Count
}
# Submissions per second actually achieved, from the first to the last submit row.
function Jtl-AchievedRate([string]$jtl) {
    if (-not (Test-Path -LiteralPath $jtl)) { return 0.0 }
    $ts = @(Import-Csv -LiteralPath $jtl | Where-Object { [string]$_.label -match 'submit' } | ForEach-Object { [long]$_.timeStamp })
    if ($ts.Count -lt 2) { return 0.0 }
    $m = $ts | Measure-Object -Minimum -Maximum
    $span = ($m.Maximum - $m.Minimum) / 1000.0
    if ($span -le 0) { return 0.0 }
    return [math]::Round(($ts.Count - 1) / $span, 1)
}
# Reset + seed + warm-up several products at once (the skewed profile).
function Reset-Seed-Warm-Multi([hashtable]$products) {
    & (Join-Path $repoRoot "scripts\reset-and-seed.ps1") -Container $pg -Full -RedisContainer $redis -RabbitMqContainer $rabbit -Products $products *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    & (Join-Path $repoRoot "scripts\warm-up.ps1") -Container $redis -Products $products -Force *> $null
    return ($LASTEXITCODE -eq 0)
}

# ================================================================== preamble
try {
    Write-Output "== Environment"
    $dockerOk = $false
    for ($i = 1; $i -le 5; $i++) { docker info *> $null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }; Start-Sleep 3 }
    if (-not $dockerOk) { throw "SETUP ERROR: docker is not reachable (docker info failed)" }
    if (-not (Test-Path -LiteralPath $jmeterBat)) { throw "SETUP ERROR: JMeter not found at $jmeterBat" }
    foreach ($port in $nginxHostPort, $rabbitPromHostPort) {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw "port $port is already in use" }
    }

    # own env file + override file + cert
    Write-EnvFile "1000r/s" "500"
    @"
services:
  rabbitmq:
    ports:
      - "${rabbitPromHostPort}:15692"
"@ | Set-Content -LiteralPath $overrideFile -Encoding ASCII
    $pfx = Join-Path $repoRoot "infra\openiddict.pfx"
    if (-not (Test-Path -LiteralPath $pfx)) {
        & dotnet dev-certs https -v -ep $pfx -p "99426be9-e087-4c7d-b9cb-566835df936d" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $pfx)) { throw "SETUP ERROR: could not create $pfx" }
    }

    # build + up (prerequisite for every case)
    Write-Output "== Build + up (project $project)"
    Compose @("build")
    if ($LASTEXITCODE -ne 0) { throw "SETUP ERROR: docker compose build failed" }
    Compose @("up", "-d")
    if ($LASTEXITCODE -ne 0) { throw "SETUP ERROR: docker compose up -d failed" }
    $up = Wait-Until {
        $pgH = (docker inspect -f '{{.State.Health.Status}}' $pg 2>$null); $rdH = (docker inspect -f '{{.State.Health.Status}}' $redis 2>$null); $rbH = (docker inspect -f '{{.State.Health.Status}}' $rabbit 2>$null)
        ($pgH -eq "healthy") -and ($rdH -eq "healthy") -and ($rbH -eq "healthy")
    } 180
    if (-not $up) { throw "SETUP ERROR: postgres/redis/rabbitmq did not become healthy" }
    # Wait for the .NET services and the rest too: Order Service only starts after
    # its one-shot migration completes, so "running" here also means the
    # migrations finished and the API is up.
    $allUp = Wait-Until {
        $ok = $true
        foreach ($c in @("$project-order-service-1", "$project-inventory-service-1", "$project-process-worker-1", $nginx, $prom, "$project-grafana-1")) {
            if ((docker inspect -f '{{.State.Running}}' $c 2>$null) -ne "true") { $ok = $false }
        }
        $ok
    } 240
    if (-not $allUp) { throw "SETUP ERROR: the services did not all start" }

    # ---------------------------------------------------------- A
    if ($Cases -contains "A") {
        Write-Output "== A. all services healthy + Prometheus targets"
        $svcNames = @($nginx, "$project-order-service-1", "$project-inventory-service-1", "$project-process-worker-1", $prom, "$project-grafana-1")
        $allRunning = $true
        foreach ($c in $svcNames) { if (-not (docker inspect -f '{{.State.Running}}' $c 2>$null) -or (docker inspect -f '{{.State.Running}}' $c 2>$null) -ne "true") { $allRunning = $false } }
        Check "A: all services healthy/running" $allRunning "containers=$($svcNames -join ',')"
        $wantJobs = @("order-service", "inventory-service", "process-worker", "rabbitmq", "prometheus")
        # Prometheus scrapes every 5 s and needs a first scrape per target; wait up
        # to 60 s for all five jobs to report up before checking.
        $promUp = Wait-Until {
            $u = @{}
            foreach ($t in @(Prom-Targets)) { $job = [string]$t.labels.job; if ($t.health -eq "up") { $u[$job] = $true } }
            (@($wantJobs | Where-Object { -not $u.ContainsKey($_) }).Count -eq 0)
        } 60
        $targets = Prom-Targets
        $jobsUp = @{}
        foreach ($t in $targets) { $job = [string]$t.labels.job; if ($t.health -eq "up") { $jobsUp[$job] = $true } }
        $allJobsUp = ($promUp -and @($wantJobs | Where-Object { -not $jobsUp.ContainsKey($_) }).Count -eq 0)
        Check "A: Prometheus reports order/inventory/process-worker/rabbitmq/prometheus up" $allJobsUp "up=$(@($jobsUp.Keys | Sort-Object) -join ',')"
        # Every running container must have the json-file log cap (30 GiB root volume).
        $allIds = @(docker compose -p $project -f $composeFile -f $overrideFile ps -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $logCapsOk = $true; $logDetail = ""
        foreach ($cid in $allIds) {
            $driver = (docker inspect -f '{{.HostConfig.LogConfig.Type}}' $cid 2>$null | Out-String).Trim()
            # max-size has a hyphen, which a Go template cannot name directly, and
            # 5.1 strips the quotes an `index` form would need: read it as JSON.
            $logCfg = (docker inspect -f '{{json .HostConfig.LogConfig.Config}}' $cid 2>$null | Out-String).Trim()
            $maxSize = ""; try { $maxSize = [string]($logCfg | ConvertFrom-Json).'max-size' } catch { }
            $cname = (docker inspect -f '{{.Name}}' $cid 2>$null | Out-String).Trim().TrimStart('/')
            if ($driver -ne "json-file" -or $maxSize -ne "50m") { $logCapsOk = $false; $logDetail += "$cname=$driver/$maxSize; " }
        }
        Check "A: every running container logs json-file capped at 50m" ($logCapsOk -and $allIds.Count -gt 0) $logDetail
    }

    # ---------------------------------------------------------- B
    if ($Cases -contains "B") {
        Write-Output "== B. C1 baseline through the gateway (low ORDER_RATE)"
        & (Join-Path $repoRoot "scripts\reset-and-seed.ps1") -Container $pg *> $null
        Write-EnvFile "5r/s" "1"
        Compose @("up", "-d", "nginx") | Out-Null
        if (-not (Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxHostPort/nginx-health" -TimeoutSec 3).StatusCode -eq 200 } catch { $false } } 60)) { throw "nginx did not come up for case B" }
        $c1 = Post-Nginx "/api/c1/orders" $workProduct
        Check "B: POST /api/c1/orders via Nginx returns 200 with a Result" ($c1.Status -eq 200 -and $c1.Body -match 'result') "status=$($c1.Status) body=$($c1.Body)"
        $o1 = Post-Nginx "/api/orders" $workProduct
        Check "B: POST /api/orders via Nginx returns 201" ($o1.Status -eq 201) "status=$($o1.Status)"
        $rndStatus = 0
        try { $rndStatus = [int](Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxHostPort/not-a-route" -TimeoutSec 10).StatusCode } catch { if ($_.Exception.Response) { $rndStatus = [int]$_.Exception.Response.StatusCode } }
        Check "B: GET a random path returns 404" ($rndStatus -eq 404) "status=$rndStatus"
        $c1b = @(); $ob = @()
        for ($i = 0; $i -lt 25; $i++) { $c1b += (Post-Nginx "/api/c1/orders" $workProduct).Status; $ob += (Post-Nginx "/api/orders" $workProduct).Status }
        $c1_429 = @($c1b | Where-Object { $_ -eq 429 }).Count
        $o_429 = @($ob | Where-Object { $_ -eq 429 }).Count
        Check "B: burst above ORDER_RATE gives 429 on both /api/c1/orders and /api/orders" ($c1_429 -gt 0 -and $o_429 -gt 0) "c1-429=$c1_429 orders-429=$o_429"
        Write-EnvFile "1000r/s" "500"
        Compose @("up", "-d", "nginx") | Out-Null
        if (-not (Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxHostPort/nginx-health" -TimeoutSec 3).StatusCode -eq 200 } catch { $false } } 60)) { throw "nginx did not come back after case B" }
    }

    # ---------------------------------------------------------- C
    if ($Cases -contains "C") {
        Write-Output "== C. C4 replicas 1, 2, 4"
        $stock = 5000
        foreach ($n in @(1, 2, 4)) {
            Compose @("up", "-d", "--scale", "inventory-service=$n") | Out-Null
            if (-not (Wait-Until { @(Service-Containers "inventory-service").Count -eq $n } 90)) { throw "inventory-service did not scale to $n" }
            if (-not (Reset-Seed-Warm $workProduct $stock)) { throw "reset+seed+warm-up failed for $n replicas" }
            # Sample pg_stat_activity every 2 s DURING the load (background job),
            # so the peak is observed rather than one after-the-fact reading.
            $connFile = Join-Path $env:TEMP "ec2v-conn-$n.txt"
            Remove-Item -LiteralPath $connFile -Force -ErrorAction SilentlyContinue
            $connJob = Start-Job -ArgumentList $pg, $connFile -ScriptBlock {
                param($pgContainer, $outFile)
                while ($true) {
                    $v = ("SELECT count(*) FROM pg_stat_activity;" | docker exec -i $pgContainer psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>$null | Out-String).Trim()
                    if ($v -match '^\d+$') { Add-Content -LiteralPath $outFile -Value $v }
                    Start-Sleep -Seconds 2
                }
            }
            $loadStartEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $jtl = Join-Path $env:TEMP "ec2v-replicas-$n.jtl"
            Run-Jmeter "replicas-$n" @("-JproductsFile=products.csv", "-Jthreads1=50", "-Jrate1=50", "-Jduration1=30", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") $jtl | Out-Null
            $drained = Wait-Until {
                ((Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct' AND `"State`" NOT IN ('Completed','Rejected');") -eq 0) -and
                ((Int1 "SELECT count(*) FROM order_service.outbox_events WHERE `"Published`" = false;") -eq 0)
            } 240
            Stop-Job -Job $connJob -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $connJob -Force -ErrorAction SilentlyContinue | Out-Null
            $connPeak = 0
            if (Test-Path -LiteralPath $connFile) {
                $connVals = @(Get-Content -LiteralPath $connFile | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                if ($connVals.Count -gt 0) { $connPeak = ($connVals | Measure-Object -Maximum).Maximum }
            }
            $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C4 -ProductId $workProduct -InitialStock $stock -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
            $vExit = $LASTEXITCODE
            Check "C: replicas=$n validator -Config C4 passes after drain" ($drained -and $vExit -eq 0 -and $v -match '5\. accepted-order accounting\s+PASS') "drained=$drained exit=$vExit"
            $cSub2xx = Jtl-2xxSubmitCount $jtl
            $cOrders = Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct';"
            Check "C: replicas=$n orders in DB ($cOrders) equal 2xx submits ($cSub2xx) and > 0" ($cOrders -gt 0 -and $cOrders -eq $cSub2xx) "orders=$cOrders submits=$cSub2xx"
            $logBad = $false
            $pgLog = docker logs $pg 2>&1 | Out-String
            if ($pgLog -match 'too many clients') { $logBad = $true }
            foreach ($rc in @("$project-order-service-1") + @(Service-Containers "inventory-service")) {
                $rl = docker logs $rc 2>&1 | Out-String
                if ($rl -match 'too many clients|Timeout during connection|Maximum Pool Size') { $logBad = $true }
            }
            Check "C: replicas=$n no 'too many clients' or pool timeout in postgres/order/replica logs" (-not $logBad)
            $maxConn = Int1 "SHOW max_connections;"
            Check "C: replicas=$n pg_stat_activity peak ($connPeak) stays below max_connections ($maxConn)" ($connPeak -gt 0 -and $connPeak -lt $maxConn) "peak=$connPeak max=$maxConn"
            $allConsumed = $true
            foreach ($rc in @(Service-Containers "inventory-service")) {
                if (@(docker logs --since $loadStartEpoch $rc 2>&1 | Select-String -SimpleMatch " for product ").Count -lt 1) { $allConsumed = $false }
            }
            Check "C: replicas=$n every replica consumed >= 1 message" ($allConsumed -and @(Service-Containers "inventory-service").Count -eq $n) "consumed_all=$allConsumed"
            $invUp = @(Prom-Targets | Where-Object { $_.labels.job -eq "inventory-service" -and $_.health -eq "up" }).Count
            Check "C: replicas=$n Prometheus reports $n inventory targets" ($invUp -eq $n) "targets=$invUp"
        }
    }

    # ---------------------------------------------------------- D
    if ($Cases -contains "D") {
        Write-Output "== D. RabbitMQ rates via -RabbitMqMetricsUrl during a load"
        if (-not (Reset-Seed-Warm $workProduct 5000)) { throw "reset+seed+warm-up failed for case D" }
        $dOut = Join-Path $env:TEMP "ec2v-collector-d"
        Remove-Item -LiteralPath $dOut -Recurse -Force -ErrorAction SilentlyContinue # a stale STOP file ends the collector at once
        New-Item -ItemType Directory -Force -Path $dOut | Out-Null
        $dCollector = Join-Path $repoRoot "scripts\collect-run-metrics.ps1"
        $dProc = Start-Process -FilePath "powershell" -ArgumentList @(
            "-NoProfile", "-File", $dCollector,
            "-RunId", "ec2v-d",
            "-OutDir", $dOut,
            "-IntervalSeconds", "5",
            "-DurationSeconds", "0",
            "-RabbitMqContainer", $rabbit,
            "-RabbitMqMetricsUrl", "http://localhost:$rabbitPromHostPort/metrics",
            "-RedisContainer", $redis,
            "-PostgresContainer", $pg
        ) -RedirectStandardOutput (Join-Path $dOut "collector.out.log") -RedirectStandardError (Join-Path $dOut "collector.err.log") -WindowStyle Hidden -PassThru
        $dStarted = Wait-Until { Test-Path -LiteralPath (Join-Path $dOut "collector.json") } 20
        Check "D: rates collector started against 15692" $dStarted "json=$(Join-Path $dOut 'collector.json')"
        Start-Sleep 3
        Run-Jmeter "d-load" @("-JproductsFile=products.csv", "-Jthreads1=40", "-Jrate1=30", "-Jduration1=20", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") (Join-Path $dOut "load.jtl") | Out-Null
        Start-Sleep 6
        Set-Content -LiteralPath (Join-Path $dOut "STOP") -Value "stop" -Encoding ASCII
        for ($i = 0; $i -lt 30; $i++) { $dProc.Refresh(); if ($dProc.HasExited) { break }; Start-Sleep 1 }
        $dRows = @()
        if (Test-Path -LiteralPath (Join-Path $dOut "samples.csv")) { $dRows = @(Import-Csv -LiteralPath (Join-Path $dOut "samples.csv")) }
        $rateRows = @($dRows | Where-Object { $_.source -eq "rabbitmq" -and ($_.name -in @("publish_rate", "deliver_get_rate", "ack_rate")) } | Sort-Object utc_time)
        $firstTime = $null
        if ($rateRows.Count -gt 0) { $firstTime = ($rateRows | ForEach-Object { [string]$_.utc_time } | Sort-Object | Select-Object -First 1) }
        $firstRates = @($rateRows | Where-Object { [string]$_.utc_time -eq $firstTime })
        $firstOk = $true
        foreach ($rn in "publish_rate", "deliver_get_rate", "ack_rate") {
            $fr = @($firstRates | Where-Object { $_.name -eq $rn })
            if ($fr.Count -ne 1 -or [string]$fr[0].value -ne "unavailable") { $firstOk = $false }
        }
        Check "D: first sample is unavailable (no previous counter)" ($rateRows.Count -ge 3 -and $firstOk) "first_rows=$(@($firstRates | ForEach-Object { "$($_.name)=$($_.value)" }) -join ',')"
        $pubVals = @($dRows | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "publish_rate" } | ForEach-Object { try { [double]$_.value } catch { } } | Where-Object { $null -ne $_ })
        $delVals = @($dRows | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "deliver_get_rate" } | ForEach-Object { try { [double]$_.value } catch { } } | Where-Object { $null -ne $_ })
        $ackVals = @($dRows | Where-Object { $_.source -eq "rabbitmq" -and $_.name -eq "ack_rate" } | ForEach-Object { try { [double]$_.value } catch { } } | Where-Object { $null -ne $_ })
        $pubMax = 0.0; if ($pubVals.Count -gt 0) { $pubMax = ($pubVals | Measure-Object -Maximum).Maximum }
        $delMax = 0.0; if ($delVals.Count -gt 0) { $delMax = ($delVals | Measure-Object -Maximum).Maximum }
        $ackMax = 0.0; if ($ackVals.Count -gt 0) { $ackMax = ($ackVals | Measure-Object -Maximum).Maximum }
        Check "D: rate rows numeric and > 0 at some sample (publish/deliver/ack)" ($pubMax -gt 0 -and $delMax -gt 0 -and $ackMax -gt 0) "publish_max=$pubMax deliver_max=$delMax ack_max=$ackMax"
    }

    # ---------------------------------------------------------- E
    if ($Cases -contains "E") {
        Write-Output "== E. workload profiles"
        # single-product profiles (steady / ramp / spike / hot): C4, one product.
        $profiles = @(
            @{ Name = "steady"; Stock = 2000; Extra = @("-JproductsFile=products.csv", "-Jthreads1=20", "-Jrate1=10", "-Jduration1=15", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") },
            @{ Name = "ramp"; Stock = 2000; Extra = @("-JproductsFile=products.csv", "-Jthreads1=10", "-Jrate1=5", "-Jduration1=10", "-Jthreads2=20", "-Jrate2=15", "-Jduration2=10", "-Jthreads3=30", "-Jrate3=30", "-Jduration3=10", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") },
            @{ Name = "spike"; Stock = 2000; Extra = @("-JproductsFile=products.csv", "-Jthreads1=10", "-Jrate1=3", "-Jduration1=10", "-Jthreads2=40", "-Jrate2=40", "-Jduration2=10", "-Jthreads3=10", "-Jrate3=3", "-Jduration3=10", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") },
            @{ Name = "hot"; Stock = 2000; Extra = @("-JproductsFile=products-hot.csv", "-Jthreads1=20", "-Jrate1=10", "-Jduration1=15", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") }
        )
        foreach ($p in $profiles) {
            if (-not (Reset-Seed-Warm $workProduct $p.Stock)) { throw "reset+seed+warm-up failed for profile $($p.Name)" }
            $jtl = Join-Path $env:TEMP "ec2v-profile-$($p.Name).jtl"
            Run-Jmeter $p.Name $p.Extra $jtl | Out-Null
            $errs = Jtl-Non2xxCount $jtl
            Check "E: profile $($p.Name) JTL has rows and every submission 2xx" ($errs -eq 0) "errors=$errs"
            Wait-Until { (Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct' AND `"State`" NOT IN ('Completed','Rejected');") -eq 0 } 180 | Out-Null
            $sub2xx = Jtl-2xxSubmitCount $jtl
            $ordCount = Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct';"
            Check "E: profile $($p.Name) orders in DB ($ordCount) equal 2xx submits ($sub2xx) and > 0" ($ordCount -gt 0 -and $ordCount -eq $sub2xx) "orders=$ordCount submits=$sub2xx"
            $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C4 -ProductId $workProduct -InitialStock $p.Stock -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
            Check "E: profile $($p.Name) validator passes" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
        }

        # overload + recovery: a low gateway rate so stage 2 actually overloads it.
        if (-not (Reset-Seed-Warm $workProduct 2000)) { throw "reset+seed+warm-up failed for overload-recovery" }
        Write-EnvFile "10r/s" "5"
        Compose @("up", "-d", "nginx") | Out-Null
        if (-not (Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxHostPort/nginx-health" -TimeoutSec 3).StatusCode -eq 200 } catch { $false } } 60)) { throw "nginx did not come up for overload-recovery" }
        $ovJtl = Join-Path $env:TEMP "ec2v-profile-overload-recovery.jtl"
        Run-Jmeter "overload-recovery" @("-JproductsFile=products.csv", "-Jthreads1=10", "-Jrate1=3", "-Jduration1=10", "-Jthreads2=40", "-Jrate2=60", "-Jduration2=10", "-Jthreads3=10", "-Jrate3=3", "-Jduration3=10", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") $ovJtl | Out-Null
        $ov429 = Jtl-Stage429Count $ovJtl 2
        Check "E: overload-recovery stage 2 produced 429s" ($ov429 -gt 0) "stage2_429=$ov429"
        $ovStage3Non2xx = Jtl-StageNon2xxCount $ovJtl 3
        Check "E: overload-recovery stage 3 has only 2xx" ($ovStage3Non2xx -eq 0) "stage3_non2xx=$ovStage3Non2xx"
        Wait-Until { (Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct' AND `"State`" NOT IN ('Completed','Rejected');") -eq 0 } 240 | Out-Null
        $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C4 -ProductId $workProduct -InitialStock 2000 -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
        Check "E: overload-recovery validator passes after drain" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
        Write-EnvFile "1000r/s" "500"
        Compose @("up", "-d", "nginx") | Out-Null
        if (-not (Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://localhost:$nginxHostPort/nginx-health" -TimeoutSec 3).StatusCode -eq 200 } catch { $false } } 60)) { throw "nginx did not come back after overload-recovery" }

        # skewed: four products (70/15/10/5 shares), all seeded and validated.
        $skewProducts = @("flash-product-1", "flash-product-2", "flash-product-3", "flash-product-4")
        $skewStocks = @{ "flash-product-1" = 2000; "flash-product-2" = 2000; "flash-product-3" = 2000; "flash-product-4" = 2000 }
        if (-not (Reset-Seed-Warm-Multi $skewStocks)) { throw "reset+seed+warm-up failed for skewed" }
        $skJtl = Join-Path $env:TEMP "ec2v-profile-skewed.jtl"
        Run-Jmeter "skewed" @("-JproductsFile=products-skewed.csv", "-Jthreads1=20", "-Jrate1=10", "-Jduration1=15", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") $skJtl | Out-Null
        $skErr = Jtl-Non2xxCount $skJtl
        Check "E: skewed JTL has rows and every submission 2xx" ($skErr -eq 0) "errors=$skErr"
        Wait-Until {
            $allDone = $true
            foreach ($sp in $skewProducts) {
                if ((Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$sp' AND `"State`" NOT IN ('Completed','Rejected');") -ne 0) { $allDone = $false }
            }
            $allDone
        } 240 | Out-Null
        $skCounts = @{}
        foreach ($sp in $skewProducts) { $skCounts[$sp] = Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$sp';" }
        $skEach = $true; foreach ($sp in $skewProducts) { if ($skCounts[$sp] -lt 1) { $skEach = $false } }
        $skLargest = $true; foreach ($sp in @("flash-product-2", "flash-product-3", "flash-product-4")) { if ($skCounts[$sp] -gt $skCounts["flash-product-1"]) { $skLargest = $false } }
        Check "E: skewed each product has >=1 order and flash-product-1 is largest" ($skEach -and $skLargest) "counts=$(@($skewProducts | ForEach-Object { "$_=$($skCounts[$_])" }) -join ',')"
        $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C4 -Products $skewStocks -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
        Check "E: skewed validator -Products passes" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

        # c1 baseline: /api/c1/orders has no order id, so no poll rows may exist.
        & (Join-Path $repoRoot "scripts\reset-and-seed.ps1") -Container $pg -Products @{ $workProduct = 2000 } *> $null
        if ($LASTEXITCODE -ne 0) { throw "reset+seed failed for c1 profile" }
        $c1Jtl = Join-Path $env:TEMP "ec2v-profile-c1.jtl"
        Run-Jmeter "c1" @("-JproductsFile=products.csv", "-Jthreads1=20", "-Jrate1=10", "-Jduration1=15", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") $c1Jtl "/api/c1/orders" | Out-Null
        $c1Sub = Jtl-SubmitCount $c1Jtl
        $c1Poll = Jtl-PollCount $c1Jtl
        $c1Err = Jtl-Non2xxCount $c1Jtl
        Check "E: c1 JTL has submit rows and every submission 2xx" ($c1Sub -gt 0 -and $c1Err -eq 0) "submits=$c1Sub errors=$c1Err"
        Check "E: c1 has no poll rows" ($c1Poll -eq 0) "polls=$c1Poll"
        $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C1 -ProductId $workProduct -InitialStock 2000 -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
        Check "E: c1 validator -Config C1 passes" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

        # below / equal / above inventory. threads1=5, loops1=N/5, duration1=600 so
        # the loop is never cut short by the scheduler; the exact total is 5 x (N/5) = N.
        foreach ($vol in @(@{ Name = "below"; N = 10; S = 20; Loops = 2 }, @{ Name = "equal"; N = 20; S = 20; Loops = 4 }, @{ Name = "above"; N = 30; S = 20; Loops = 6 })) {
            if (-not (Reset-Seed-Warm $workProduct $vol.S)) { throw "reset+seed+warm-up failed for volume $($vol.Name)" }
            $jtl = Join-Path $env:TEMP "ec2v-volume-$($vol.Name).jtl"
            Run-Jmeter "volume-$($vol.Name)" @("-JproductsFile=products-hot.csv", "-Jthreads1=5", "-Jrate1=1000", "-Jduration1=600", "-Jloops1=$($vol.Loops)", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") $jtl | Out-Null
            $subCount = Jtl-SubmitCount $jtl
            Check "E: volume $($vol.Name) JTL has exactly $($vol.N) submit rows" ($subCount -eq $vol.N) "submits=$subCount"
            Wait-Until { (Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct' AND `"State`" NOT IN ('Completed','Rejected');") -eq 0 } 240 | Out-Null
            $sc = Scard $workProduct
            $want = [math]::Min($vol.N, $vol.S)
            Check "E: volume $($vol.Name) reservations match min(requests, stock)" ($sc -eq $want) "scard=$sc want=$want (requests=$($vol.N) stock=$($vol.S))"
            $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C4 -ProductId $workProduct -InitialStock $vol.S -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
            Check "E: volume $($vol.Name) validator passes" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
        }
    }

    # ---------------------------------------------------------- F
    if ($Cases -contains "F") {
        Write-Output "== F. open-loop mode: achieved rate against requested rate"
        $openStock = 3000
        foreach ($cfg in @(@{ Name = "C1"; Path = "/api/c1/orders" }, @{ Name = "C2"; Path = "/api/orders" })) {
            foreach ($o in @(@{ Rate = 10; Threads = 20 }, @{ Rate = 50; Threads = 50 })) {
                $tag = "$($cfg.Name) at $($o.Rate)/s"
                if ($cfg.Name -eq "C1") {
                    & (Join-Path $repoRoot "scripts\reset-and-seed.ps1") -Container $pg -Products @{ $workProduct = $openStock } *> $null
                    if ($LASTEXITCODE -ne 0) { throw "reset+seed failed for $tag" }
                } elseif (-not (Reset-Seed-Warm $workProduct $openStock)) { throw "reset+seed+warm-up failed for $tag" }
                $jtl = Join-Path $env:TEMP "ec2v-open-$($cfg.Name)-$($o.Rate).jtl"
                Run-Jmeter "open" @("-Jmode=open", "-JproductsFile=products.csv", "-Jthreads1=$($o.Threads)", "-Jrate1=$($o.Rate)", "-Jduration1=20", "-Jthreads2=0", "-Jduration2=0", "-Jthreads3=0", "-Jduration3=0", "-Jthreads4=0", "-Jduration4=0", "-Jthreads5=0", "-Jduration5=0") $jtl $cfg.Path | Out-Null
                $achieved = Jtl-AchievedRate $jtl
                Check "F: $tag achieved >= 90 % of requested" ($achieved -ge (0.9 * $o.Rate)) "achieved=$achieved requested=$($o.Rate) submits=$(Jtl-SubmitCount $jtl)"
                $polls = Jtl-PollCount $jtl
                Check "F: $tag has no poll rows" ($polls -eq 0) "polls=$polls"
                $bad = Jtl-Non2xxCount $jtl
                Check "F: $tag every submission 2xx" ($bad -eq 0) "non2xx=$bad"
                if ($cfg.Name -eq "C1") {
                    $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C1 -ProductId $workProduct -InitialStock $openStock -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
                    $vExit = $LASTEXITCODE
                    Check "F: $tag validator passes" ($vExit -eq 0) "exit=$vExit"
                } else {
                    $t0 = Get-Date
                    $drained = Wait-Until { (Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct' AND `"State`" NOT IN ('Completed','Rejected');") -eq 0 } 420
                    $drainS = [int]((Get-Date) - $t0).TotalSeconds
                    $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C2 -ProductId $workProduct -InitialStock $openStock -PgContainer $pg -RedisContainer $redis *>&1 | Out-String
                    $vExit = $LASTEXITCODE
                    $orders = Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$workProduct';"
                    $sub2xx = Jtl-2xxSubmitCount $jtl
                    Check "F: $tag drained, validator passes, one order per 2xx submission" ($drained -and $vExit -eq 0 -and $orders -gt 0 -and $orders -eq $sub2xx) "drained=$drained after ${drainS}s exit=$vExit orders=$orders submits=$sub2xx"
                }
            }
        }
    }

    # ---------------------------------------------------------- G
    if ($Cases -contains "G") {
        Write-Output "== G. run-matrix.ps1 and the queue-bound gate"
        $bounds = Join-Path $repoRoot "scripts\set-queue-bounds.ps1"
        & $bounds -Container $rabbit -Remove | Out-Null
        & $bounds -Container $rabbit -ExpectMaxLength 0 | Out-Null
        Check "G: gate passes with no policy on the broker" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
        & $bounds -Container $rabbit -MaxLength 7 | Out-Null
        & $bounds -Container $rabbit -ExpectMaxLength 0 | Out-Null
        Check "G: gate fails for C1/C2 while the policy is on the broker" ($LASTEXITCODE -eq 1) "exit=$LASTEXITCODE"
        & $bounds -Container $rabbit -ExpectMaxLength 7 | Out-Null
        Check "G: gate passes for the bound that is set" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
        $v = & (Join-Path $repoRoot "scripts\validate-correctness.ps1") -Config C2 -ProductId $workProduct -InitialStock 1 -PgContainer $pg -RedisContainer $redis -RabbitMqContainer $rabbit *>&1 | Out-String
        Check "G: validator check 6 fails for C2 while the policy is on the broker" ($LASTEXITCODE -ne 0 -and $v -match '6\. queue bound off\s+FAIL') "exit=$LASTEXITCODE"
        & $bounds -Container $rabbit -Remove | Out-Null

        $mxOut = Join-Path $env:TEMP "ec2v-matrix"
        Remove-Item -LiteralPath $mxOut -Recurse -Force -ErrorAction SilentlyContinue
        $mxBound = 50
        & (Join-Path $repoRoot "scripts\run-matrix.ps1") -Project $project -EnvFile "infra/ec2-verify.env" -ExtraComposeFile $overrideFile `
            -BackendPort $nginxHostPort -RabbitMqMetricsUrl "http://localhost:$rabbitPromHostPort/metrics" `
            -Configs C3, C2 -Rates 5 -Repeats 1 -DurationSeconds 10 -Threads 10 -Stock 1000 -QueueMaxLength $mxBound -OutDir $mxOut *>&1 | ForEach-Object { Write-Output "   $_" }
        $mxExit = $LASTEXITCODE
        Set-Location -LiteralPath $repoRoot
        Check "G: the C3 then C2 matrix exits 0" ($mxExit -eq 0) "exit=$mxExit"
        $manifests = @(Get-ChildItem -LiteralPath $mxOut -Recurse -Filter manifest.json -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json })
        $m3 = @($manifests | Where-Object { $_.config -eq "C3" }) | Select-Object -First 1
        $m2 = @($manifests | Where-Object { $_.config -eq "C2" }) | Select-Object -First 1
        Check "G: one PASS manifest for each config, with a commit and image ids" ($manifests.Count -eq 2 -and $m3.status -eq "PASS" -and $m2.status -eq "PASS" -and $m3.prepare.commit -match '^[0-9a-f]{40}$' -and $m2.prepare.images) "runs=$($manifests.Count) c3=$($m3.status)/$($m3.failed_step) c2=$($m2.status)/$($m2.failed_step)"
        Check "G: C3 ran with its bound, admission on and the shedding gateway" ($m3.prepare.queue_bound_expected -eq $mxBound -and $m3.prepare.gates.queue_bound -and $m3.prepare.admission_enabled -eq "true" -and $m3.prepare.gateway_rate -eq "200r/s") "gate='$($m3.prepare.queue_bound_gate)' admission=$($m3.prepare.admission_enabled) gateway=$($m3.prepare.gateway_rate)"
        Check "G: C2 ran after C3 with the bound gone, admission off and the open gateway" ($m2.prepare.queue_bound_expected -eq 0 -and $m2.prepare.gates.queue_bound -and $m2.prepare.admission_enabled -eq "false" -and $m2.prepare.gateway_rate -eq "10000r/s" -and $m2.started_utc -gt $m3.ended_utc) "gate='$($m2.prepare.queue_bound_gate)' admission=$($m2.prepare.admission_enabled) gateway=$($m2.prepare.gateway_rate)"
        Check "G: both runs open-loop: submissions and no poll rows" ($m3.load.submissions -gt 0 -and $m2.load.submissions -gt 0 -and $m3.load.polls -eq 0 -and $m2.load.polls -eq 0 -and $m3.jmeter_mode -eq "open") "c3=$($m3.load.submissions)/$($m3.load.polls) c2=$($m2.load.submissions)/$($m2.load.polls)"
        Check "G: both runs drained, validated, accounted and dumped" ($m3.post.drained -and $m2.post.drained -and $m3.post.validator_exit -eq 0 -and $m2.post.validator_exit -eq 0 -and $m3.post.db_dump -and $m2.post.db_dump -and $m3.post.db_accepted -eq $m3.load.submissions_2xx -and $m2.post.db_accepted -eq $m2.load.submissions_2xx) "c3_accepted=$($m3.post.db_accepted) c2_accepted=$($m2.post.db_accepted)"
        $v2Log = ""
        $v2Dir = @(Get-ChildItem -LiteralPath $mxOut -Directory -Filter "*-C2-*" -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($v2Dir) { $v2Log = Get-Content -Raw -LiteralPath (Join-Path $v2Dir.FullName "validator.log") -ErrorAction SilentlyContinue }
        Check "G: the C2 validator log shows check 6 PASS" ("$v2Log" -match '6\. queue bound off\s+PASS') "log=$($v2Dir.FullName)"
        & $bounds -Container $rabbit -ExpectMaxLength 0 | Out-Null
        $brokerClean = ($LASTEXITCODE -eq 0)
        $queuePolicies = @(docker exec $rabbit rabbitmqctl -q list_queues name policy --no-table-headers 2>$null | Where-Object { "$_" -match 'flashsale-c3-bounds' })
        Check "G: no queue on the broker carries the policy after the matrix" ($brokerClean -and $queuePolicies.Count -eq 0) "queues_with_policy=$($queuePolicies.Count)"
        $refused = & (Join-Path $repoRoot "scripts\run-matrix.ps1") -Project "infra" -Configs C2 -Rates 1 -OutDir $mxOut 2>&1 | Out-String
        Check "G: run-matrix refuses the local infra project" ($LASTEXITCODE -eq 2 -and $refused -match 'Refusing') "exit=$LASTEXITCODE"
        Set-Location -LiteralPath $repoRoot
    }
}
catch { Check "unexpected error: $($_.Exception.Message)" $false }
finally {
    if ($dProc -and -not $dProc.HasExited) { Stop-Process -Id $dProc.Id -Force -ErrorAction SilentlyContinue }
    if ($connJob) { Stop-Job -Job $connJob -ErrorAction SilentlyContinue | Out-Null; Remove-Job -Job $connJob -Force -ErrorAction SilentlyContinue | Out-Null }
    docker compose -p $project -f $composeFile -f $overrideFile down -v *> $null
    Remove-Item -LiteralPath $overrideFile -Force -ErrorAction SilentlyContinue
}

if ($checks -ne $expectedChecks) { Write-Output "FAIL  only $checks of $expectedChecks checks ran"; exit 1 }
if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output "All checks passed: the EC2 stack builds, the C1 route and C4 replicas hold, RabbitMQ rates come from Prometheus, every workload profile runs clean, open-loop mode reaches its requested rate, and the matrix leaves no queue bound behind."
exit 0
