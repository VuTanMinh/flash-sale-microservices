# ============================================================
# Drives one EC2 measurement session from the operator's PC over SSM Run Command:
# one run-matrix.ps1 call per run, repeat-major, extraction on the backend before the
# next reset, copy-back with SHA-256 checks after each round, and a cutoff before the
# safety timer. Stops at the first failed run and never reruns on its own; started
# again with the same -Out, it skips the runs that already passed.
#
#   -Plan official        the 66 official runs (docs/week14-official-runs.md)
#   -Plan supplementary   the 18 supplementary runs (docs/week14-supplementary-runs.md)
#   -Plan backpressure    the Process Worker A/B, frozen against fixed Worker on the
#                         same hosts (docs/week14-backpressure-fix.md)
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\ec2-session.ps1 -Plan backpressure `
#     -Backend <i-backend> -JMeter <i-jmeter> -BackendIp <backend-private-ip> `
#     -TimerEndUtc <apply time + timer, ISO 8601> -Out <local session folder>
#
# Every run uses run-matrix.ps1's frozen defaults; only -Configs, -Replicas and -Rates
# are passed (and -Stock 2000 for the supplementary sell-out cells). For -Plan
# backpressure the driver first prepares the backend once (Prepare-AB below): the
# deploy built every image from the branch head, so the Worker image there is the fixed
# one; it is tagged :fix, and the Worker from the tag w14-official is built as :frozen.
# Order Service and Inventory are byte-identical between the two, so one build serves
# both. Before each run the driver points the Worker at that run's image with a
# compose override (infra/worker-<version>.yml on the host), recreates only the Worker,
# waits until it consumes ProcessWorker.StockReserved, and passes the same override to
# run-matrix, so its own compose up keeps that image. Each run's official.json records
# the Worker version and image id; run-matrix's manifest records every image id.
# The driver copies itself into -Out at start, so the evidence holds the exact code.
# Helpers: ec2-ssm-run.ps1 (run a bash script on a host) and ec2-ssm-file.ps1 (copy a
# file back with a SHA-256 check), next to this script.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Backend,
    [Parameter(Mandatory = $true)][string]$JMeter,
    [Parameter(Mandatory = $true)][string]$BackendIp,
    [Parameter(Mandatory = $true)][string]$TimerEndUtc,
    [Parameter(Mandatory = $true)][string]$Out,
    [ValidateSet("official", "supplementary", "backpressure")][string]$Plan = "official",
    [int[]]$Rounds = @(1, 2, 3),
    [string]$AwsExe = "C:\Users\Lenovo\AppData\Local\Programs\Amazon\AWSCLIV2\aws.exe",
    [switch]$DryRun,
    [switch]$SkipC2At400
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent $PSScriptRoot
$ssm = Join-Path $PSScriptRoot "ec2-ssm-run.ps1"; $ssmFile = Join-Path $PSScriptRoot "ec2-ssm-file.ps1"
$runMatrix = Join-Path $PSScriptRoot "run-matrix.ps1"
$timerEnd = [DateTime]::Parse($TimerEndUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal')
$cells = @()
if ($Plan -eq "official") {
    # cell = config, replicas, rate, stock (0 = the frozen default, -Stock not passed), Worker version
    foreach ($c in "C1", "C2") { foreach ($r in 50, 100, 200) { $cells += , @($c, 1, $r, 0, "") } }
    foreach ($r in 50, 100, 200, 400) { $cells += , @("C3", 1, $r, 0, "") }
    foreach ($n in 1, 2, 4) { foreach ($r in 50, 100, 200, 400) { $cells += , @("C4", $n, $r, 0, "") } }
} elseif ($Plan -eq "backpressure") {
    # the same three cells on the frozen Worker, then on the fixed one, in every round
    foreach ($v in "frozen", "fix") {
        $cells += , @("C3", 1, 200, 0, $v); $cells += , @("C3", 1, 400, 0, $v); $cells += , @("C4", 1, 400, 0, $v)
    }
} else {
    # C2 at 400/s last, so a drain failure there cannot block the other cells
    $cells += , @("C1", 1, 400, 0, "")
    foreach ($c in "C1", "C2", "C3") { $cells += , @($c, 1, 200, 2000, "") }
    $cells += , @("C2", 1, 100, 0, "")
    if (-not $SkipC2At400) { $cells += , @("C2", 1, 400, 0, "") }
}
New-Item -ItemType Directory -Force $Out | Out-Null
if (-not $DryRun) { Copy-Item -LiteralPath $PSCommandPath, $ssm, $ssmFile -Destination $Out -Force }
$csv = Join-Path $Out "runs.csv"
if (-not (Test-Path $csv)) { "repeat,order,config,replicas,rate,worker_version,run_id,status,achieved_per_s,submissions_2xx,db_accepted,drain_s,validator_exit,failed_step,started_utc" | Set-Content $csv -Encoding ASCII }
function Host-Run([string]$inst, [string]$name, [string]$body, [int]$t = 300) {
    $f = Join-Path $Out "$name.sh"; [IO.File]::WriteAllText($f, ("set -uo pipefail`nexec 2>&1`n" + $body).Replace("`r", ""))
    return (@(& powershell -NoProfile -File $ssm -InstanceId $inst -ScriptFile $f -TimeoutSeconds $t -AwsExe $AwsExe) -join "`n")
}
function Done([string]$dir, [string]$cfg, [int]$n, [int]$rate) {
    foreach ($d in @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-$cfg-r$n-$($rate)rps-rep1" })) {
        $m = Join-Path $d.FullName "manifest.json"
        if ((Test-Path $m) -and ((Get-Content -Raw $m | ConvertFrom-Json).status -eq "PASS")) { return $true }
    }
    return $false
}

"Week 14 $Plan runs: $($cells.Count) cells x rounds $($Rounds -join ',') ; timer ends $($timerEnd.ToString('o')) ; cutoff = run 12 min + final copy 45 min + 60 min margin"
if ($Plan -eq "backpressure" -and -not $DryRun) {
    # Prepare-AB: once per session, idempotent
    $prep = @"
cd /opt/flash-sale-microservices
git fetch -q --tags origin
echo "head `$(git rev-parse HEAD) tag `$(git rev-parse 'w14-official^{commit}')"
docker tag flashsale-process-worker:10.0 flashsale-process-worker:fix
rm -rf /opt/w14-official; git worktree prune; git worktree add -f /opt/w14-official w14-official >/dev/null 2>&1
docker build -q -t flashsale-process-worker:frozen -f /opt/w14-official/src/FlashSale.ProcessWorker/Dockerfile /opt/w14-official >/dev/null
for v in frozen fix; do printf 'services:\n  process-worker:\n    image: flashsale-process-worker:%s\n' `$v > infra/worker-`$v.yml; done
echo "image frozen `$(docker image inspect -f '{{.Id}}' flashsale-process-worker:frozen)"
echo "image fix `$(docker image inspect -f '{{.Id}}' flashsale-process-worker:fix)"
"@
    $p = Host-Run $Backend "prepare-ab" $prep 1800
    Set-Content (Join-Path $Out "prepare-ab.log") $p -Encoding UTF8
    $imgFrozen = ([regex]::Match($p, 'image frozen (sha256:[0-9a-f]+)')).Groups[1].Value
    $imgFix = ([regex]::Match($p, 'image fix (sha256:[0-9a-f]+)')).Groups[1].Value
    "prepare-ab: frozen $imgFrozen fix $imgFix"
    if (-not $imgFrozen -or -not $imgFix -or $imgFrozen -eq $imgFix) { "PREPARE FAILED: two distinct Worker images are needed"; exit 1 }
}
foreach ($rep in $Rounds) {
    $roundDir = Join-Path $Out "rep$rep"; New-Item -ItemType Directory -Force $roundDir | Out-Null
    $order = 0
    foreach ($cell in $cells) {
        $order++
        $cfg, $n, $rate, $stock, $version = $cell
        # the back-pressure plan keeps each Worker version's runs in their own folder
        $repDir = $(if ($version) { Join-Path $roundDir $version } else { $roundDir }); New-Item -ItemType Directory -Force $repDir | Out-Null
        if (Done $repDir $cfg $n $rate) { "skip rep$rep $cfg r$n $rate/s $version (PASS already)"; continue }
        $now = (Get-Date).ToUniversalTime()
        if ($now.AddMinutes(12 + 45 + 60) -gt $timerEnd) { "CUTOFF before rep$rep $cfg r$n $rate/s at $($now.ToString('HH:mm:ss'))Z"; $script:cut = $true; break }
        "== rep$rep #$order $cfg r$n $rate/s$(if ($stock -gt 0) { " stock $stock" })$(if ($version) { " worker $version" }) $(Get-Date -Format HH:mm:ss)"
        if ($DryRun) { continue }
        Set-Location -LiteralPath $repoRoot
        $extra = @{}   # hashtable splat: an array splat would bind positionally
        if ($stock -gt 0) { $extra["Stock"] = $stock }
        $workerImage = ""
        if ($version) {
            $extra["ExtraComposeFile"] = "infra/worker-$version.yml"
            $sw = @"
cd /opt/flash-sale-microservices
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml -f infra/worker-$version.yml up -d --no-deps process-worker >/dev/null 2>&1
n=0; for i in `$(seq 1 90); do n=`$(docker exec infra-rabbitmq-1 rabbitmqctl -q list_queues name consumers --no-table-headers 2>/dev/null | awk '`$1=="ProcessWorker.StockReserved"{print `$2}'); [ "`${n:-0}" -ge 1 ] && break; sleep 2; done
echo "worker_image `$(docker inspect -f '{{.Image}}' infra-process-worker-1) consumers `${n:-0}"
"@
            $swOut = Host-Run $Backend ("switch-rep$rep-$version-$cfg-$rate") $sw 300
            $mm = [regex]::Match($swOut, 'worker_image (sha256:[0-9a-f]+) consumers (\d+)')
            $workerImage = $mm.Groups[1].Value; $consumers = [int]("0" + $mm.Groups[2].Value)
            "   worker $version image $workerImage consumers $consumers"
            if (-not $workerImage -or $consumers -lt 1) { "   WORKER SWITCH FAILED: stopping"; $script:failedRun = $true; break }
        }
        $startUtc = (Get-Date).ToUniversalTime().ToString("o")
        & $runMatrix -Transport Ssm -BackendInstance $Backend -JMeterInstance $JMeter -BackendHost $BackendIp -AwsExe $AwsExe `
            -Configs $cfg -Replicas "$n" -Rates $rate -Repeats 1 -OutDir $repDir @extra 2>&1 | ForEach-Object { "   $_" }
        $mxExit = $LASTEXITCODE
        $dir = Get-ChildItem $repDir -Directory | Where-Object { $_.Name -like "*-$cfg-r$n-$($rate)rps-rep1" } | Sort-Object Name | Select-Object -Last 1
        if ($null -eq $dir) { "   NO RUN FOLDER (matrix exit $mxExit): stopping"; exit 1 }
        $id = $dir.Name; $mfPath = Join-Path $dir.FullName "manifest.json"
        $mf = $null; if (Test-Path $mfPath) { $mf = Get-Content -Raw $mfPath | ConvertFrom-Json }
        $planDoc = @{ official = "docs/week14-official-runs.md"; supplementary = "docs/week14-supplementary-runs.md"; backpressure = "docs/week14-backpressure-fix.md" }[$Plan]
        [ordered]@{ official_repeat = $rep; round_order = $order; config = $cfg; replicas = $n; requested_per_s = $rate; stock = $(if ($stock -gt 0) { $stock } else { 100000 })
            run_id = $id; driver_started_utc = $startUtc; plan = $planDoc; kind = $Plan; worker_version = $version; worker_image = $workerImage } |
            ConvertTo-Json | Set-Content (Join-Path $dir.FullName "official.json") -Encoding UTF8
        if ($null -ne $mf -and $null -ne $mf.load -and $mf.load.first_ms) {
            $fromIso = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$mf.load.first_ms).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $toIso = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$mf.load.last_ms).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $b = @"
cd /opt/flash-sale-microservices
HOME=/root pwsh -NoProfile -File scripts/extract-run-metrics.ps1 -RunId $id -RunDir /tmp/matrix/$id -Container infra-postgres-1 -From $fromIso -To $toIso > /tmp/matrix/$id/extract.log 2>&1
echo "extract exit `$?"
ls /tmp/matrix/$id | tr '\n' ' '; echo
for c in `$(docker ps -q); do docker inspect -f '{{.Name}} restarts={{.RestartCount}}' `$c; done | grep -v 'restarts=0' || echo 'no restarts'
df -h / | tail -1 | awk '{print "disk " `$5}'
echo "too many clients: `$(docker logs --since 15m infra-postgres-1 2>&1 | grep -c 'too many clients')"
echo "reconciliation by state: `$(docker logs --since $startUtc infra-order-service-1 2>&1 | grep -oE 'Reconciliation: order [^ ]+ stuck in [A-Za-z]+' | awk '{print `$NF}' | sort | uniq -c | awk '{printf "%s=%s ", `$2, `$1}')"
git rev-parse HEAD; git status --porcelain | grep -v '^?? ' | head -3 || true
"@
            $h = Host-Run $Backend ("post-rep$rep-$version-$cfg-r$n-$rate") $b 600
            Set-Content (Join-Path $dir.FullName "host-post.log") $h -Encoding UTF8
            ($h -split "`n" | Where-Object { $_ -match 'extract exit|restarts=|no restarts|disk |too many|reconciliation by state' }) | ForEach-Object { "   $_" }
        }
        $st = $(if ($mf) { $mf.status } else { "NO-MANIFEST" })
        ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14}" -f $rep, $order, $cfg, $n, $rate, $version, $id, $st, $mf.load.achieved_per_s, $mf.load.submissions_2xx, $mf.post.db_accepted, $mf.post.drain_seconds, $mf.post.validator_exit, $mf.failed_step, $startUtc) | Add-Content $csv -Encoding ASCII
        "   RESULT rep$rep $version $id $st ach=$($mf.load.achieved_per_s) 2xx=$($mf.load.submissions_2xx) acc=$($mf.post.db_accepted) drain=$($mf.post.drain_seconds)s val=$($mf.post.validator_exit) step=$($mf.failed_step)"
        if ($mxExit -ne 0 -or $st -ne "PASS") { "RUN FAILED: rep$rep $cfg r$n $rate/s $version ($id). Stopping; copy back, diagnose, ask before any rerun."; $script:failedRun = $true; break }
    }
    if ($DryRun) { continue }
    # copy back this round (both hosts idle now)
    "== copy-back rep$rep $(Get-Date -Format HH:mm:ss)"
    $bundleDir = Join-Path $Out "bundles"; New-Item -ItemType Directory -Force $bundleDir | Out-Null
    $ids = @(Get-ChildItem $roundDir -Directory -Recurse | Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") } | ForEach-Object { $_.Name })
    if ($ids.Count -gt 0) {
        $list = ($ids -join ' ')
        Host-Run $Backend "bundle-b-rep$rep" "cd /tmp/matrix`ntar czf /tmp/w14-rep$rep-backend.tgz --exclude='db.dump' --exclude='STOP' $list docker-stats.csv`nls -la /tmp/w14-rep$rep-backend.tgz | cut -c24-" 600 | Select-Object -Last 2
        Host-Run $JMeter "bundle-j-rep$rep" "cd /tmp/matrix`ntar czf /tmp/w14-rep$rep-jtl.tgz $list`nls -la /tmp/w14-rep$rep-jtl.tgz | cut -c24-" 600 | Select-Object -Last 2
        $jobs = @()
        foreach ($x in @(@($Backend, "/tmp/w14-rep$rep-backend.tgz", "w14-rep$rep-backend.tgz"), @($JMeter, "/tmp/w14-rep$rep-jtl.tgz", "w14-rep$rep-jtl.tgz"))) {
            $jobs += Start-Process powershell -ArgumentList '-NoProfile', '-File', $ssmFile, '-Mode', 'get', '-InstanceId', $x[0], '-RemotePath', $x[1], '-LocalPath', (Join-Path $bundleDir $x[2]), '-AwsExe', $AwsExe -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path $bundleDir "$($x[2]).out") -RedirectStandardError (Join-Path $bundleDir "$($x[2]).err")
        }
        $jobs | ForEach-Object { $_.WaitForExit() }
        Get-Content (Join-Path $bundleDir "w14-rep$rep-*.out"), (Join-Path $bundleDir "w14-rep$rep-*.err") | ForEach-Object { "   $_" }
    }
    "== copy-back rep$rep done $(Get-Date -Format HH:mm:ss)"
    if ($script:failedRun -or $script:cut) { break }
}
if ($script:failedRun) { "SESSION STOPPED: failed run"; exit 1 }
if ($script:cut) { "SESSION STOPPED: cutoff"; exit 3 }
"SESSION DONE $(Get-Date -Format HH:mm:ss)"
