# ============================================================
# Week 11 milestone, Task B: a run-time collector for the measurements that
# only exist during a run (queue depth, oldest message age, RabbitMQ publish/
# deliver/ack rates, Redis latency, database connections, host CPU/RAM, and
# every flashsale_* Prometheus sample).
#
#   powershell -File .\scripts\collect-run-metrics.ps1 -RunId pilot-001
#
# Defaults target the local stack: RabbitMQ management on http://localhost:15672
# (flashsale/flashsale_dev), Redis container "infra-redis-1", PostgreSQL
# container "infra-postgres-1", and the three services' /metrics URLs from
# infra/prometheus.yml (Order https://localhost:44314/metrics, Inventory
# https://localhost:44379/metrics, Worker http://localhost:5100/metrics).
#
# Every -IntervalSeconds (default 5) it appends one row per value to
# <OutDir>/samples.csv, in long format:
#
#   utc_time,source,name,labels,value
#
# Sources (the "name" written for each; "labels" is a ";"-joined key=value list):
#   rabbitmq : messages_ready, messages_unacknowledged, oldest_age_seconds
#              (labels "queue=<q>"), plus publish_rate, deliver_get_rate and
#              ack_rate from the overview message_stats. The queue counts and
#              head_message_timestamp are management statistics refreshed every
#              collect_statistics_interval (5 s by default), so a value can be
#              that interval stale. oldest_age_seconds = now - head_message_timestamp
#              (0 when the queue is empty).
#   redis    : calls and usec (labels "command=evalsha"/"command=eval") from
#              INFO commandstats. Both are cumulative; mean latency per interval
#              is delta(usec)/delta(calls) (extraction in Task C). A fresh Redis
#              with no Lua call yet reports calls=0/usec=0 (a legitimate zero,
#              not a failure).
#   postgres : connections (labels "usename=<u>") from pg_stat_activity, one row
#              per usename.
#   service  : every flashsale_* sample plus process_cpu_seconds_total and
#              process_working_set_bytes, scraped from each service's /metrics
#              (labels "service=<job>" plus the sample's own labels).
#   host     : cpu_percent and memory_used_bytes/memory_total_bytes. Windows:
#              performance counters + CIM. Linux: /proc/stat and /proc/meminfo.
#              The Linux branch ran in mcr.microsoft.com/powershell:7.4-ubuntu-22.04
#              (tests/evidence/20261014T150746Z-collector-linux-host.log);
#              confirm it on the EC2 host in Week 12.
#   collector: sample_duration_ms (labels "") -- how long the interval's
#              sampling took, in milliseconds, so the real cadence is visible.
#
# A source that fails is recorded as a row with value "unavailable" and the
# error in labels, never as 0; failures are counted and printed at the end, and
# the other sources keep sampling. The collector never stops for one source.
# A per-value field that has not arrived yet (for example a queue count that
# is still a management statistic) is also "unavailable", never a false 0.
#
# One sample takes about 4 s on the local Windows host (two docker exec calls
# of about 1 s each, plus the HTTP scrapes), so -IntervalSeconds must be at
# least 5 s. On the EC2 host, read sample_duration_ms in the pilot and set the
# interval from it.
#
# <OutDir>/collector.json is written once at start (run id, interval, endpoints,
# host OS, start time, git commit). Run with -DurationSeconds 0 to sample until
# a file <OutDir>/STOP appears; -DurationSeconds N to sample for N seconds.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$OutDir = "",
    [int]$IntervalSeconds = 5,
    [int]$DurationSeconds = 0,
    [string]$RabbitMqUrl = "http://localhost:15672",
    [string]$RabbitMqUser = "flashsale",
    [string]$RabbitMqPassword = "flashsale_dev",
    [string]$RedisContainer = "infra-redis-1",
    [string]$PostgresContainer = "infra-postgres-1",
    [string]$OrderMetricsUrl = "https://localhost:44314/metrics",
    [string]$InventoryMetricsUrl = "https://localhost:44379/metrics",
    [string]$WorkerMetricsUrl = "http://localhost:5100/metrics"
)

# Continue, not Stop: under Windows PowerShell 5.1, redirected stderr from a
# native command (docker, git) becomes a terminating error under Stop.
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$inv = [Globalization.CultureInfo]::InvariantCulture

if ($OutDir -eq "") { $OutDir = Join-Path (Join-Path (Get-Location).Path "experiments") $RunId }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { Write-Output "FATAL: cannot create $OutDir"; exit 1 }

$csvPath = Join-Path $OutDir "samples.csv"
$jsonPath = Join-Path $OutDir "collector.json"
$stopFile = Join-Path $OutDir "STOP"
$onWindows = ($env:OS -eq "Windows_NT")

# git commit (read-only; the collector still works outside a checkout).
$gitCommit = ""
try { $gitCommit = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim() } catch { }
if (-not $gitCommit) { $gitCommit = "unknown" }

Set-Content -LiteralPath $csvPath -Value "utc_time,source,name,labels,value" -Encoding UTF8
$script:rowCount = 0
$script:sourceFailures = 0
$script:prevCpu = $null   # Linux /proc/stat delta, @(total, idle)
$script:pending = New-Object System.Collections.ArrayList   # rows buffered per interval

# collector.json -- the RabbitMQ password is deliberately NOT written (A3).
[ordered]@{
    run_id = $RunId
    interval_seconds = $IntervalSeconds
    start_time_utc = [DateTime]::UtcNow.ToString("o", $inv)
    host_os = $(if ($onWindows) { "Windows" } else { "Linux" })
    git_commit = $gitCommit
    endpoints = [ordered]@{
        rabbitmq_management_url = $RabbitMqUrl
        rabbitmq_user = $RabbitMqUser
        redis_container = $RedisContainer
        postgres_container = $PostgresContainer
        order_metrics_url = $OrderMetricsUrl
        inventory_metrics_url = $InventoryMetricsUrl
        worker_metrics_url = $WorkerMetricsUrl
    }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${RabbitMqUser}:${RabbitMqPassword}")) }

# Windows PowerShell 5.1 has no -SkipCertificateCheck; HttpWebRequest honours
# the process-wide callback instead. pwsh 6+ uses -SkipCertificateCheck per
# request (Fetch-Content below).
if (($PSVersionTable.PSVersion.Major -lt 6) -and (($OrderMetricsUrl -like "https://*") -or ($InventoryMetricsUrl -like "https://*") -or ($WorkerMetricsUrl -like "https://*"))) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { return $true }
}

function Fmt([double]$v) { return $v.ToString("R", $inv) }
function Csv-Field([string]$s) {
    if ($s -match '[,"\r\n]') { return '"' + ($s -replace '"', '""') + '"' }
    return $s
}
function Write-Row([string]$time, [string]$source, [string]$name, [string]$labels, [string]$value) {
    $line = (Csv-Field $time) + "," + (Csv-Field $source) + "," + (Csv-Field $name) + "," + (Csv-Field $labels) + "," + (Csv-Field $value)
    [void]$script:pending.Add($line)
    $script:rowCount++
}
function Flush-Rows {
    if ($script:pending.Count -gt 0) {
        Add-Content -LiteralPath $csvPath -Value @($script:pending) -Encoding UTF8
        $script:pending.Clear()
    }
}
function Write-Metric([string]$time, [string]$source, [string]$name, [string]$labels, $value) {
    if ($null -eq $value) { Write-Row $time $source $name $labels "unavailable" }
    else { Write-Row $time $source $name $labels "$value" }
}
function Write-Unavailable([string]$time, [string]$source, [string]$error) {
    $script:sourceFailures++
    $clean = ($error -replace '[\r\n\t]+', ' ' -replace ',', ' ' -replace '"', "'").Trim()
    if ($clean.Length -gt 200) { $clean = $clean.Substring(0, 200) }
    Write-Row $time $source "unavailable" "error=$clean" "unavailable"
}
function Mq([string]$method, [string]$path) {
    $req = @{ Method = $method; Headers = $auth; Uri = "$RabbitMqUrl/api$path"; TimeoutSec = 3; UseBasicParsing = $true }
    return Invoke-RestMethod @req
}
function Fetch-Content([string]$url) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return (Invoke-WebRequest -SkipCertificateCheck -Uri $url -TimeoutSec 2).Content
    }
    return (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2).Content
}

function Sample-RabbitMq([string]$t) {
    try {
        $overview = Mq Get "/overview"
        # PowerShell 5.1: Invoke-RestMethod returns a JSON array as one object;
        # enumerate it so each element is a single queue.
        $queues = @(Mq Get "/queues" | ForEach-Object { $_ })
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $publish = 0.0; $deliver = 0.0; $ack = 0.0
        if ($null -ne $overview.message_stats) {
            if ($null -ne $overview.message_stats.publish_details) { $publish = [double]$overview.message_stats.publish_details.rate }
            if ($null -ne $overview.message_stats.deliver_get_details) { $deliver = [double]$overview.message_stats.deliver_get_details.rate }
            if ($null -ne $overview.message_stats.ack_details) { $ack = [double]$overview.message_stats.ack_details.rate }
        }
        Write-Row $t "rabbitmq" "publish_rate" "" (Fmt $publish)
        Write-Row $t "rabbitmq" "deliver_get_rate" "" (Fmt $deliver)
        Write-Row $t "rabbitmq" "ack_rate" "" (Fmt $ack)
        foreach ($q in $queues) {
            if ($null -eq $q.name) { continue }
            $qname = [string]$q.name
            Write-Metric $t "rabbitmq" "messages_ready" "queue=$qname" $q.messages_ready
            Write-Metric $t "rabbitmq" "messages_unacknowledged" "queue=$qname" $q.messages_unacknowledged
            if ($null -ne $q.head_message_timestamp) {
                $age = [long]($now - [long]$q.head_message_timestamp)
                if ($age -lt 0) { $age = 0 }
                Write-Row $t "rabbitmq" "oldest_age_seconds" "queue=$qname" "$age"
            } elseif (($null -ne $q.messages_ready -and [long]$q.messages_ready -gt 0) -or ($null -ne $q.messages_unacknowledged -and [long]$q.messages_unacknowledged -gt 0)) {
                # The queue has messages but no head timestamp yet (statistics
                # lag): that is not an age of 0.
                Write-Row $t "rabbitmq" "oldest_age_seconds" "queue=$qname" "unavailable"
            } else {
                Write-Row $t "rabbitmq" "oldest_age_seconds" "queue=$qname" "0"
            }
        }
    } catch {
        Write-Unavailable $t "rabbitmq" $_.Exception.Message
    }
}

function Sample-Redis([string]$t) {
    try {
        $out = @(docker exec $RedisContainer redis-cli INFO commandstats 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "redis-cli commandstats failed (exit $LASTEXITCODE): $($out -join ' ')" }
        $found = $false
        foreach ($line in $out) {
            if ($line -match '^cmdstat_(eval|evalsha):calls=(\d+),usec=(\d+)') {
                $cmd = $Matches[1]; $calls = [long]$Matches[2]; $usec = [long]$Matches[3]
                Write-Row $t "redis" "calls" "command=$cmd" "$calls"
                Write-Row $t "redis" "usec" "command=$cmd" "$usec"
                $found = $true
            }
        }
        if (-not $found) {
            Write-Row $t "redis" "calls" "command=evalsha" "0"
            Write-Row $t "redis" "usec" "command=evalsha" "0"
        }
    } catch {
        Write-Unavailable $t "redis" $_.Exception.Message
    }
}

function Sample-Postgres([string]$t) {
    try {
        $sql = "SELECT coalesce(usename,'(none)') AS u, count(*) AS c FROM pg_stat_activity GROUP BY usename ORDER BY usename;"
        $out = @($sql | docker exec -i $PostgresContainer psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE): $($out -join ' ')" }
        foreach ($line in $out) {
            if ($line -match '^(.+)\|(\d+)$') {
                $u = $Matches[1].Trim(); $c = [int]$Matches[2]
                if ($u -ne "(none)" -and $u -ne "") { Write-Row $t "postgres" "connections" "usename=$u" "$c" }
            }
        }
    } catch {
        Write-Unavailable $t "postgres" $_.Exception.Message
    }
}

function Sample-Service([string]$url, [string]$service, [string]$t) {
    try {
        $content = Fetch-Content $url
        foreach ($line in ($content -split "`n")) {
            $line = $line.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            if ($line -notmatch '^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^}]*)\})?\s+(\S+)$') { continue }
            $name = $Matches[1]; $raw = $Matches[3]; $value = $Matches[4]
            if ($name -like "flashsale_*" -or $name -eq "process_cpu_seconds_total" -or $name -eq "process_working_set_bytes") {
                $labels = "service=$service"
                if ($raw) { $labels = $labels + ";" + $raw }
                Write-Row $t "service" $name $labels $value
            }
        }
    } catch {
        Write-Unavailable $t "service" ("$service : " + $_.Exception.Message)
    }
}

function Sample-Host([string]$t) {
    try {
        if ($onWindows) {
            $cpu = 0.0
            $cpuObj = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $cpuObj) { $cpu = [double]$cpuObj.PercentProcessorTime }
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
            $totalKb = [double]$os.TotalVisibleMemorySize
            $freeKb = [double]$os.FreePhysicalMemory
            $usedBytes = [long](($totalKb - $freeKb) * 1024)
            $totalBytes = [long]($totalKb * 1024)
            if ($usedBytes -lt 0) { $usedBytes = 0 }
            Write-Row $t "host" "cpu_percent" "" (Fmt $cpu)
            Write-Row $t "host" "memory_used_bytes" "" "$usedBytes"
            Write-Row $t "host" "memory_total_bytes" "" "$totalBytes"
        } else {
            # Linux (EC2 host, Week 12): read /proc/stat and /proc/meminfo.
            # Checked in a Linux container (2026-10-14); confirm on EC2 in Week 12.
            $stat = Get-Content -LiteralPath /proc/stat -TotalCount 1 -ErrorAction Stop
            $parts = @($stat -split '\s+' | Where-Object { $_ -ne '' })
            $idle = 0L; $total = 0L
            if ($parts.Count -ge 5) {
                $idle = [long]$parts[4] + [long]$parts[5]   # idle + iowait
                for ($i = 1; $i -lt $parts.Count; $i++) { $total += [long]$parts[$i] }
            }
            $isFirstCpuSample = ($null -eq $script:prevCpu)
            $cpu = 0.0
            if (-not $isFirstCpuSample -and ($total - $script:prevCpu[0]) -gt 0) {
                $dTotal = $total - $script:prevCpu[0]; $dIdle = $idle - $script:prevCpu[1]
                $cpu = 100.0 * (1.0 - ($dIdle / $dTotal))
                if ($cpu -lt 0) { $cpu = 0.0 }
            }
            $script:prevCpu = @($total, $idle)
            $memTotal = 0L; $memAvail = 0L
            foreach ($line in (Get-Content -LiteralPath /proc/meminfo -ErrorAction Stop)) {
                if ($line -match '^MemTotal:\s+(\d+) kB') { $memTotal = [long]$Matches[1] * 1024 }
                elseif ($line -match '^MemAvailable:\s+(\d+) kB') { $memAvail = [long]$Matches[1] * 1024 }
            }
            $usedBytes = [long]($memTotal - $memAvail); if ($usedBytes -lt 0) { $usedBytes = 0 }
            if ($isFirstCpuSample) {
                Write-Row $t "host" "cpu_percent" "reason=first sample, no previous reading" "unavailable"
            } else {
                Write-Row $t "host" "cpu_percent" "" (Fmt $cpu)
            }
            Write-Row $t "host" "memory_used_bytes" "" "$usedBytes"
            Write-Row $t "host" "memory_total_bytes" "" "$memTotal"
        }
    } catch {
        Write-Unavailable $t "host" $_.Exception.Message
    }
}

# ================================================================== run
$startUtc = [DateTime]::UtcNow
$next = $startUtc
while ($true) {
    if ($DurationSeconds -le 0 -and (Test-Path -LiteralPath $stopFile)) { break }
    $sampleStart = [DateTime]::UtcNow
    $t = $sampleStart.ToString("yyyy-MM-ddTHH:mm:ss.fff", $inv) + "Z"
    Sample-RabbitMq $t
    Sample-Redis $t
    Sample-Postgres $t
    Sample-Service $OrderMetricsUrl "order-service" $t
    Sample-Service $InventoryMetricsUrl "inventory-service" $t
    Sample-Service $WorkerMetricsUrl "process-worker" $t
    Sample-Host $t
    $sampleMs = [int]([DateTime]::UtcNow - $sampleStart).TotalMilliseconds
    Write-Row $t "collector" "sample_duration_ms" "" "$sampleMs"
    Flush-Rows
    if ($DurationSeconds -gt 0 -and (([DateTime]::UtcNow - $startUtc).TotalSeconds -ge $DurationSeconds)) { break }
    $next = $next.AddSeconds($IntervalSeconds)
    $sleepMs = [int](($next - [DateTime]::UtcNow).TotalMilliseconds)
    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs } else { $next = [DateTime]::UtcNow }
}
Write-Output "collect-run-metrics finished: run=${RunId} interval=${IntervalSeconds}s rows=$($script:rowCount) source_failures=$($script:sourceFailures) out_dir=$OutDir"
exit 0
