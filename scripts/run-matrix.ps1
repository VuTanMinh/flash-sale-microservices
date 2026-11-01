# ============================================================
# Week 13 (TP-X06): the pilot and official run matrix, configs x load levels x
# repeats, on the EC2 Compose stack. For each run: config setup, full reset + seed
# + warm-up, gates, collector, one open-loop workload.jmx load, drain, validator,
# database dump, and one manifest.json. Stops at the first run that fails.
#
# From the operator's PC, driving both EC2 hosts over SSM Run Command:
#   powershell -File .\scripts\run-matrix.ps1 -Transport Ssm -BackendInstance i-... -JMeterInstance i-... `
#     -BackendHost <backend-private-ip> -Configs C1,C2,C3,C4 -Rates 50,200 -Repeats 1 -OutDir <folder>
#
# Locally against a scratch stack (`-Project` must never be the local `infra`
# stack on this PC; verify-ec2-stack.ps1 case G runs it this way):
#   powershell -File .\scripts\run-matrix.ps1 -Project flashsale-ec2v -EnvFile infra/ec2-verify.env `
#     -ExtraComposeFile <override.yml> -BackendPort 18080 -Configs C3,C2 -Rates 5 -OutDir <folder>
#
# Config setup (the same table is in docs/deployment.md section 5f):
#   C1, C2  ADMISSION_ENABLED=false, gateway limit far above the offered rate,
#           queue bound removed, 1 Inventory replica
#   C3      ADMISSION_ENABLED=true, gateway -ShedOrderRate/-ShedOrderBurst,
#           queue bound -QueueMaxLength, 1 Inventory replica
#   C4      C3 with each of -Replicas Inventory replicas
# The admission limits themselves stay in the env file.
#
# Gates, read back from the running stack, not from what was requested: the
# policy (set-queue-bounds.ps1 -ExpectMaxLength), Admission__Enabled in the Order
# Service container, ORDER_RATE in the Nginx container, the replica count and the
# OrderPlaced consumers. A failed gate fails the run before any load is sent.
#
# -Step runs one backend step and is how the two transports share their code:
# Local calls it in this process, Ssm runs it on the backend with pwsh.
# A rate shortfall is data, not a failure: the manifest reports the achieved rate.
# ============================================================
param(
    [ValidateSet("matrix", "prepare", "collect-start", "post")][string]$Step = "matrix",
    [string[]]$Configs = @("C1", "C2", "C3", "C4"),
    [string[]]$Rates = @("50"),
    [int]$Repeats = 1,
    [string[]]$Replicas = @("1", "2", "4"),
    [int]$DurationSeconds = 60,
    [int]$Threads = 0,
    [int]$Stock = 100000,
    [int]$QueueMaxLength = 5,
    [string]$OpenOrderRate = "10000r/s",
    [string]$OpenOrderBurst = "5000",
    [string]$ShedOrderRate = "200r/s",
    [string]$ShedOrderBurst = "100",
    [int]$DrainTimeoutSeconds = 900,
    [string]$Product = "flash-product-1",
    [ValidateSet("Local", "Ssm")][string]$Transport = "Local",
    [string]$BackendInstance = "",
    [string]$JMeterInstance = "",
    [string]$BackendHost = "localhost",
    [int]$BackendPort = 80,
    [string]$AwsExe = "aws",
    [string]$AwsProfile = "flashsale-plan",
    [string]$HostRepo = "/opt/flash-sale-microservices",
    [string]$HostOutRoot = "/tmp/matrix",
    [string]$JMeterExe = "D:\tools\apache-jmeter-5.6.3\bin\jmeter.bat",
    [string]$OutDir = "",
    [string]$Project = "infra",
    [string]$EnvFile = "infra/ec2.env",
    [string]$ExtraComposeFile = "",
    [string]$RabbitMqMetricsUrl = "",
    [string]$Config = "",
    [int]$ReplicaCount = 1,
    [string]$RunId = "",
    [string]$RunDir = ""
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location -LiteralPath $repoRoot
$pg = "$Project-postgres-1"; $redis = "$Project-redis-1"; $rabbit = "$Project-rabbitmq-1"
$nginx = "$Project-nginx-1"; $order = "$Project-order-service-1"

function Compose([string[]]$composeArgs) {
    $files = @("-f", "infra/docker-compose.ec2.yml")
    if ($ExtraComposeFile) { $files += @("-f", $ExtraComposeFile) }
    & docker compose -p $Project --env-file $EnvFile @files @composeArgs 2>&1 | ForEach-Object { "$_" }
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $pg psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return (@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne "" }) -join "`n")
}
function Int1([string]$sql) {
    $v = Sql $sql
    if ($v -notmatch '^-?\d+$') { return -1 }
    return [int]$v
}
function Wait-Until([scriptblock]$cond, [int]$seconds) { for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return [bool](& $cond) }
function Container-Env([string]$container, [string]$name) {
    foreach ($line in @(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $container 2>$null)) {
        if ("$line".StartsWith("$name=")) { return "$line".Substring($name.Length + 1).Trim() }
    }
    return ""
}
function Container-Ip([string]$container) {
    return (docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $container 2>$null | Out-String).Trim()
}
function Inventory-Containers {
    return @(docker ps --filter "label=com.docker.compose.project=$Project" --filter "label=com.docker.compose.service=inventory-service" --format '{{.Names}}' 2>$null | Where-Object { $_ })
}
function Queue-Consumers([string]$queue) {
    foreach ($line in @(docker exec $rabbit rabbitmqctl -q list_queues name consumers --no-table-headers 2>$null)) {
        $parts = @("$line" -split "\s+")
        if ($parts[0] -eq $queue) { return [int]$parts[1] }
    }
    return 0
}
function Is-Shedding([string]$cfg) { return ($cfg -in "C3", "C4") }
# One unit per run: systemd can still hold the last run's unit when the next one starts.
function Collector-Unit { return "matrix-collector-$(Split-Path -Leaf $RunDir)" }

# ------------------------------------------------------------------ backend steps
function Step-Prepare {
    $shed = Is-Shedding $Config
    $admission = $(if ($shed) { "true" } else { "false" })
    $gwRate = $(if ($shed) { $ShedOrderRate } else { $OpenOrderRate })
    $gwBurst = $(if ($shed) { $ShedOrderBurst } else { $OpenOrderBurst })
    $bound = $(if ($shed) { $QueueMaxLength } else { 0 })
    # The shell wins over --env-file, so these three do not touch the env file.
    $env:ADMISSION_ENABLED = $admission; $env:ORDER_RATE = $gwRate; $env:ORDER_BURST = $gwBurst
    try {
        Compose @("up", "-d", "--scale", "inventory-service=$ReplicaCount") | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "compose up failed"; return 1 }
        # Nginx keeps the address it resolved at start, so it must follow Order Service.
        Compose @("up", "-d", "--no-deps", "--force-recreate", "nginx") | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "nginx recreate failed"; return 1 }
    }
    finally { Remove-Item Env:ADMISSION_ENABLED, Env:ORDER_RATE, Env:ORDER_BURST -ErrorAction SilentlyContinue }

    # An empty POST is a 400 from a live Order Service, and takes nothing from stock.
    $apiUp = Wait-Until { (docker exec $nginx curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost/api/orders" 2>$null | Out-String).Trim() -match '^4' } 180
    $consumersUp = Wait-Until { (@(Inventory-Containers).Count -eq $ReplicaCount) -and ((Queue-Consumers "OrderPlaced") -ge $ReplicaCount) } 180

    if ($shed) { & (Join-Path $PSScriptRoot "set-queue-bounds.ps1") -Container $rabbit -MaxLength $QueueMaxLength | Out-Null }
    else { & (Join-Path $PSScriptRoot "set-queue-bounds.ps1") -Container $rabbit -Remove | Out-Null }

    & (Join-Path $PSScriptRoot "reset-and-seed.ps1") -Container $pg -Full -RedisContainer $redis -RabbitMqContainer $rabbit -Products @{ $Product = $Stock } *> $null
    $resetOk = ($LASTEXITCODE -eq 0)
    & (Join-Path $PSScriptRoot "warm-up.ps1") -Container $redis -Products @{ $Product = $Stock } -Force *> $null
    $warmOk = ($LASTEXITCODE -eq 0)

    $boundText = @(& (Join-Path $PSScriptRoot "set-queue-bounds.ps1") -Container $rabbit -ExpectMaxLength $bound) -join " "
    $boundOk = ($LASTEXITCODE -eq 0)
    $seenAdmission = Container-Env $order "Admission__Enabled"
    $seenRate = Container-Env $nginx "ORDER_RATE"
    $seenReplicas = @(Inventory-Containers).Count
    $gates = [ordered]@{
        reset_seed_warm = ($resetOk -and $warmOk)
        api_up          = [bool]$apiUp
        consumers_up    = [bool]$consumersUp
        queue_bound     = $boundOk
        admission       = ($seenAdmission -eq $admission)
        gateway         = ($seenRate -eq $gwRate)
        replicas        = ($seenReplicas -eq $ReplicaCount)
    }
    $images = [ordered]@{}
    foreach ($c in @($order, "$Project-process-worker-1") + @(Inventory-Containers | Select-Object -First 1)) {
        $images[$c] = (docker inspect -f '{{.Image}}' $c 2>$null | Out-String).Trim()
    }
    $dirty = @(git status --porcelain --untracked-files=no 2>$null).Count -gt 0
    $state = [ordered]@{
        commit = (git rev-parse HEAD 2>$null | Out-String).Trim(); commit_dirty = $dirty; images = $images
        queue_bound_expected = $bound; queue_bound_gate = $boundText
        admission_enabled = $seenAdmission; gateway_rate = $seenRate
        replicas = $seenReplicas; gates = $gates
    }
    Write-Output ("PREPARE " + ($state | ConvertTo-Json -Compress -Depth 5))
    if (@($gates.Values | Where-Object { -not $_ }).Count -gt 0) { return 1 }
    return 0
}

function Step-CollectStart {
    New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    $collector = Join-Path $PSScriptRoot "collect-run-metrics.ps1"
    $a = @("-NoProfile", "-File", $collector, "-RunId", $RunId, "-OutDir", $RunDir, "-DurationSeconds", "0",
        "-RabbitMqContainer", $rabbit, "-RedisContainer", $redis, "-PostgresContainer", $pg)
    if ($IsLinux) {
        $inv = @(Inventory-Containers | ForEach-Object { "http://$(Container-Ip $_):8080/metrics" }) -join ","
        $a += @("-RabbitMqMetricsUrl", "http://$(Container-Ip $rabbit):15692/metrics", "-InventoryMetricsUrl", $inv,
            "-OrderMetricsUrl", "http://$(Container-Ip $order):8080/metrics",
            "-WorkerMetricsUrl", "http://$(Container-Ip "$Project-process-worker-1"):8080/metrics")
        & systemd-run "--unit=$(Collector-Unit)" --collect "--working-directory=$repoRoot" --setenv=HOME=/root pwsh @a 2>&1 | Out-Null
    } else {
        # The service metrics are on the Compose network, out of reach from a Docker Desktop host.
        if ($RabbitMqMetricsUrl) { $a += @("-RabbitMqMetricsUrl", $RabbitMqMetricsUrl) }
        $p = Start-Process -FilePath "powershell" -ArgumentList $a -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $RunDir "collector.out.log") -RedirectStandardError (Join-Path $RunDir "collector.err.log")
        Set-Content -LiteralPath (Join-Path $RunDir "collector.pid") -Value $p.Id -Encoding ASCII
    }
    $started = Wait-Until { Test-Path -LiteralPath (Join-Path $RunDir "collector.json") } 30
    Write-Output "COLLECTOR started=$started"
    if ($started) { return 0 } else { return 1 }
}

function Collector-Running {
    if ($IsLinux) { return ((systemctl is-active (Collector-Unit) 2>$null | Out-String).Trim() -in "active", "activating", "deactivating") }
    $pidFile = Join-Path $RunDir "collector.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    return ($null -ne (Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue))
}

function Step-Post {
    $notDone = "SELECT (SELECT count(*) FROM order_service.orders WHERE `"State`" NOT IN ('Completed','Rejected')) + (SELECT count(*) FROM order_service.outbox_events WHERE `"Published`" = false) + (SELECT count(*) FROM inventory_service.outbox_events WHERE `"Published`" = false);"
    $t0 = Get-Date
    $drained = $true
    if ($Config -ne "C1") { $drained = Wait-Until { (Int1 $notDone) -eq 0 } $DrainTimeoutSeconds }
    $drainSeconds = [int]((Get-Date) - $t0).TotalSeconds

    Set-Content -LiteralPath (Join-Path $RunDir "STOP") -Value "stop" -Encoding ASCII
    $collectorStopped = Wait-Until { -not (Collector-Running) } 60

    $validatorLog = Join-Path $RunDir "validator.log"
    & (Join-Path $PSScriptRoot "validate-correctness.ps1") -Config $Config -ProductId $Product -InitialStock $Stock `
        -PgContainer $pg -RedisContainer $redis -RabbitMqContainer $rabbit *>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $validatorLog -Encoding UTF8
    $validatorExit = $LASTEXITCODE

    if ($Config -eq "C1") {
        $accepted = Int1 "SELECT count(*) FROM order_service.baseline_orders WHERE config = 'C1' AND product_id = '$Product';"
    } else {
        $accepted = Int1 "SELECT count(*) FROM order_service.orders WHERE `"ProductId`" = '$Product';"
    }

    # The next reset wipes these rows, and the latency breakdown needs them.
    docker exec $pg pg_dump -U flashsale -d flashsale -Fc -f /tmp/run.dump 2>&1 | Out-Null
    $dumpOk = ($LASTEXITCODE -eq 0)
    if ($dumpOk) { docker cp "${pg}:/tmp/run.dump" (Join-Path $RunDir "db.dump") 2>&1 | Out-Null; $dumpOk = ($LASTEXITCODE -eq 0) }

    $post = [ordered]@{
        drained = [bool]$drained; drain_seconds = $drainSeconds; collector_stopped = [bool]$collectorStopped
        validator_exit = $validatorExit; db_accepted = $accepted; db_dump = $dumpOk
    }
    Write-Output ("POST " + ($post | ConvertTo-Json -Compress))
    if ($drained -and $collectorStopped -and $validatorExit -eq 0 -and $dumpOk) { return 0 }
    return 1
}

if ($Step -ne "matrix") {
    switch ($Step) {
        "prepare" { $rc = Step-Prepare }
        "collect-start" { $rc = Step-CollectStart }
        "post" { $rc = Step-Post }
    }
    # Only the last value is the return code; the rest is output for the driver.
    $rcs = @($rc)
    $rcs | Select-Object -SkipLast 1 | ForEach-Object { Write-Output $_ }
    exit ([int]$rcs[-1])
}

# ------------------------------------------------------------------ transports
function Invoke-Ssm([string]$instance, [string[]]$lines, [int]$timeoutSeconds) {
    $file = Join-Path $env:TEMP ("ssm-params-" + [guid]::NewGuid() + ".json")
    [IO.File]::WriteAllText($file, (@{ commands = @($lines); executionTimeout = @("$timeoutSeconds") } | ConvertTo-Json -Compress -Depth 4))
    $cid = (& $AwsExe ssm send-command --profile $AwsProfile --instance-ids $instance --document-name AWS-RunShellScript --parameters "file://$file" --query Command.CommandId --output text 2>$null | Out-String).Trim()
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (-not $cid) { return @{ Exit = 2; Output = "SSM send-command failed" } }
    $deadline = (Get-Date).AddSeconds($timeoutSeconds + 120)
    do {
        Start-Sleep 5
        $inv = (& $AwsExe ssm get-command-invocation --profile $AwsProfile --command-id $cid --instance-id $instance --output json 2>$null | Out-String)
        $parsed = $null; if ($inv) { try { $parsed = $inv | ConvertFrom-Json } catch { } }
    } while (($null -eq $parsed -or $parsed.Status -in "Pending", "InProgress", "Delayed") -and (Get-Date) -lt $deadline)
    if ($null -eq $parsed) { return @{ Exit = 2; Output = "SSM get-command-invocation failed for $cid" } }
    return @{ Exit = [int]$parsed.ResponseCode; Output = ([string]$parsed.StandardOutputContent + "`n" + [string]$parsed.StandardErrorContent) }
}
function Invoke-BackendStep([string]$name, [hashtable]$stepArgs, [int]$timeoutSeconds) {
    $stepArgs["Step"] = $name
    $stepArgs["Product"] = $Product
    if ($Transport -eq "Local") {
        $stepArgs["Project"] = $Project; $stepArgs["EnvFile"] = $EnvFile; $stepArgs["ExtraComposeFile"] = $ExtraComposeFile
        $stepArgs["RabbitMqMetricsUrl"] = $RabbitMqMetricsUrl
        $o = @(& $PSCommandPath @stepArgs 2>&1 | ForEach-Object { "$_" })
        return @{ Exit = $LASTEXITCODE; Output = ($o -join "`n") }
    }
    $line = "cd $HostRepo && HOME=/root pwsh -NoProfile -File scripts/run-matrix.ps1"
    foreach ($k in $stepArgs.Keys) { if ("$($stepArgs[$k])" -ne "") { $line += " -$k '$($stepArgs[$k])'" } }
    return (Invoke-Ssm $BackendInstance @($line) $timeoutSeconds)
}
function Jmeter-Args([string]$path, [int]$rate, [int]$threadCount) {
    $a = @("-n", "-t", "tests/jmeter/workload.jmx", "-Jhost=$BackendHost", "-Jport=$BackendPort", "-Jpath=$path",
        "-JproductsFile=products.csv", "-Jmode=open", "-Jthreads1=$threadCount", "-Jrate1=$rate", "-Jduration1=$DurationSeconds",
        "-Jsample_variables=idempotencyKey")
    foreach ($s in 2..5) { $a += @("-Jthreads$s=0", "-Jduration$s=0") }
    return $a
}
function Local-JtlStats([string]$jtl) {
    $rows = @(); if (Test-Path -LiteralPath $jtl) { $rows = @(Import-Csv -LiteralPath $jtl) }
    $subs = @($rows | Where-Object { [string]$_.label -match 'submit' })
    $codes = [ordered]@{}
    foreach ($g in @($subs | Group-Object responseCode)) { $codes[[string]$g.Name] = $g.Count }
    $ts = @($subs | ForEach-Object { [long]$_.timeStamp } | Sort-Object)
    $span = 0.0; if ($ts.Count -gt 1) { $span = ($ts[-1] - $ts[0]) / 1000.0 }
    $achieved = 0.0; if ($span -gt 0) { $achieved = [math]::Round(($ts.Count - 1) / $span, 1) }
    return [ordered]@{
        submissions = $subs.Count; submissions_2xx = @($subs | Where-Object { [string]$_.responseCode -match '^2\d\d$' }).Count
        polls = @($rows | Where-Object { [string]$_.label -match 'poll' }).Count; achieved_per_s = $achieved; codes = $codes
    }
}
# The same numbers on the JMeter host, which has python3 and no pwsh.
function Remote-JtlStatsLines([string]$jtl) {
    return @(
        "python3 - <<'PY'",
        "import csv, json, re",
        "rows = list(csv.DictReader(open('$jtl')))",
        "subs = [r for r in rows if 'submit' in r['label']]",
        "codes = {}",
        "for r in subs: codes[r['responseCode']] = codes.get(r['responseCode'], 0) + 1",
        "ts = sorted(int(r['timeStamp']) for r in subs)",
        "span = (ts[-1] - ts[0]) / 1000.0 if len(ts) > 1 else 0.0",
        "print('JTLSTATS ' + json.dumps({'submissions': len(subs), 'submissions_2xx': sum(1 for r in subs if re.fullmatch(r'2\d\d', r['responseCode'])), 'polls': sum(1 for r in rows if 'poll' in r['label']), 'achieved_per_s': round((len(ts) - 1) / span, 1) if span else 0.0, 'codes': codes}))",
        "PY"
    )
}
function Json-After([string]$text, [string]$tag) {
    foreach ($l in @($text -split "`n")) {
        if ($l.StartsWith("$tag ")) { try { return ($l.Substring($tag.Length + 1) | ConvertFrom-Json) } catch { return $null } }
    }
    return $null
}

# ------------------------------------------------------------------ the matrix
$Configs = @($Configs | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$rateList = @($Rates | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$replicaList = @($Replicas | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { [int]$_ })
foreach ($c in $Configs) { if ($c -notin "C1", "C2", "C3", "C4") { Write-Output "Unknown config '$c'"; exit 2 } }
if ($Transport -eq "Ssm" -and (-not $BackendInstance -or -not $JMeterInstance -or $BackendHost -eq "localhost")) {
    Write-Output "-Transport Ssm needs -BackendInstance, -JMeterInstance and -BackendHost <private ip>"; exit 2
}
if ($Transport -eq "Local" -and $Project -eq "infra") {
    Write-Output "Refusing to run locally on the 'infra' project: that is the owner's stack. Use a scratch -Project."; exit 2
}
if (-not $OutDir) { Write-Output "-OutDir is required"; exit 2 }
if ($Transport -eq "Local" -and -not (Test-Path -LiteralPath $JMeterExe)) { Write-Output "SETUP ERROR: JMeter not found at $JMeterExe"; exit 2 }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$matrixId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

$cells = New-Object System.Collections.Generic.List[object]
foreach ($c in $Configs) {
    $replicaSet = $(if ($c -eq "C4") { $replicaList } else { @(1) })
    foreach ($n in $replicaSet) { foreach ($r in $rateList) { foreach ($rep in 1..$Repeats) { $cells.Add(@{ Config = $c; Replicas = $n; Rate = $r; Repeat = $rep }) } } }
}
Write-Output "Matrix $matrixId`: $($cells.Count) run(s), $($DurationSeconds) s each, transport $Transport"

$summaries = New-Object System.Collections.Generic.List[object]
$failed = $false
foreach ($cell in $cells) {
    $id = "$matrixId-$($cell.Config)-r$($cell.Replicas)-$($cell.Rate)rps-rep$($cell.Repeat)"
    $localDir = Join-Path $OutDir $id
    New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    $hostDir = $(if ($Transport -eq "Ssm") { "$HostOutRoot/$id" } else { $localDir })
    $path = $(if ($cell.Config -eq "C1") { "/api/c1/orders" } else { "/api/orders" })
    $threadCount = $(if ($Threads -gt 0) { $Threads } else { [math]::Max(20, $cell.Rate) })
    $jm = Jmeter-Args $path $cell.Rate $threadCount
    $startedUtc = (Get-Date).ToUniversalTime().ToString("o")
    Write-Output "== $id"

    $manifest = [ordered]@{
        run_id = $id; matrix_id = $matrixId; config = $cell.Config; replicas = $cell.Replicas; requested_per_s = $cell.Rate
        repeat = $cell.Repeat; duration_s = $DurationSeconds; threads = $threadCount; product = $Product; stock = $Stock
        transport = $Transport; host_dir = $hostDir; jmeter_plan = "tests/jmeter/workload.jmx"; jmeter_mode = "open"
        jmeter_args = ($jm -join " "); started_utc = $startedUtc; status = "FAIL"; failed_step = ""
    }
    $prep = Invoke-BackendStep "prepare" @{ Config = $cell.Config; ReplicaCount = $cell.Replicas; Stock = $Stock; QueueMaxLength = $QueueMaxLength; OpenOrderRate = $OpenOrderRate; OpenOrderBurst = $OpenOrderBurst; ShedOrderRate = $ShedOrderRate; ShedOrderBurst = $ShedOrderBurst } 900
    $manifest["prepare"] = Json-After $prep.Output "PREPARE"
    if ($prep.Exit -ne 0 -or $null -eq $manifest["prepare"]) {
        $manifest["failed_step"] = "prepare"; $manifest["detail"] = $prep.Output
    } else {
        $col = Invoke-BackendStep "collect-start" @{ RunId = $id; RunDir = $hostDir; RabbitMqMetricsUrl = $RabbitMqMetricsUrl } 120
        if ($col.Exit -ne 0) {
            $manifest["failed_step"] = "collect-start"; $manifest["detail"] = $col.Output
        } else {
            if ($Transport -eq "Local") {
                $jtl = Join-Path $localDir "raw.jtl"
                & $JMeterExe @jm "-l" $jtl "-j" (Join-Path $localDir "jmeter.log") *> (Join-Path $localDir "jmeter-console.log")
                $jmExit = $LASTEXITCODE
                $stats = Local-JtlStats $jtl
            } else {
                $jtl = "$HostOutRoot/$id/raw.jtl"
                $lines = @("cd $HostRepo", "mkdir -p $HostOutRoot/$id", "export HEAP='-Xms1g -Xmx2g'",
                    "/opt/jmeter/bin/jmeter $($jm -join ' ') -l $jtl -j $HostOutRoot/$id/jmeter.log > $HostOutRoot/$id/jmeter-console.log 2>&1 || exit 1") + (Remote-JtlStatsLines $jtl)
                $jmRun = Invoke-Ssm $JMeterInstance $lines ($DurationSeconds + 300)
                $jmExit = $jmRun.Exit
                $stats = Json-After $jmRun.Output "JTLSTATS"
            }
            $manifest["jmeter_exit"] = $jmExit
            $manifest["load"] = $stats
            # Always stop the collector, whatever the load did.
            $post = Invoke-BackendStep "post" @{ Config = $cell.Config; RunDir = $hostDir; Stock = $Stock; DrainTimeoutSeconds = $DrainTimeoutSeconds } ($DrainTimeoutSeconds + 300)
            $manifest["post"] = Json-After $post.Output "POST"
            $sent2xx = $(if ($null -ne $stats) { [int]$stats.submissions_2xx } else { -1 })
            if ($jmExit -ne 0 -or $null -eq $stats -or [int]$stats.submissions -le 0) { $manifest["failed_step"] = "load" }
            elseif ([int]$stats.polls -ne 0) { $manifest["failed_step"] = "open-loop (poll rows present)" }
            elseif ($post.Exit -ne 0 -or $null -eq $manifest["post"]) { $manifest["failed_step"] = "post"; $manifest["detail"] = $post.Output }
            elseif ([int]$manifest["post"].db_accepted -ne $sent2xx) { $manifest["failed_step"] = "accounting (database rows <> 2xx submissions)" }
            else { $manifest["status"] = "PASS" }
        }
    }
    $manifest["ended_utc"] = (Get-Date).ToUniversalTime().ToString("o")
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $localDir "manifest.json") -Encoding UTF8
    $summaries.Add([ordered]@{ run_id = $id; status = $manifest["status"]; failed_step = $manifest["failed_step"] })
    Write-Output "   $($manifest["status"])$(if ($manifest["failed_step"]) { " at $($manifest["failed_step"])" })"
    if ($manifest["status"] -ne "PASS") { $failed = $true; break }
}
[ordered]@{ matrix_id = $matrixId; planned_runs = $cells.Count; finished_runs = $summaries.Count; runs = $summaries } | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $OutDir "$matrixId-matrix.json") -Encoding UTF8
if ($failed) { Write-Output "MATRIX FAILED: stopped after $($summaries.Count) of $($cells.Count) run(s)."; exit 1 }
Write-Output "MATRIX PASS: $($cells.Count) run(s)."
exit 0
