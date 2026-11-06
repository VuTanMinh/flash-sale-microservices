# Local before/after check for the Process Worker back-pressure fix.
# -Version frozen: a clone checked out at 9d00bea (the official-runs code).
# -Version fix:    a clone of HEAD with the working tree's Process Worker overlaid.
# Scratch Compose project flashsale-bp on port 18080, the EC2 env values (Worker
# concurrency 20, Order consumers 4, reconciliation 120 s), new volumes, removed at the
# end. run-matrix with command-line values only: C3, a small queue bound so the Order
# Service queues fill and the Worker's publishes are refused.
param(
    [ValidateSet("frozen", "fix")][string]$Version,
    [string[]]$Rates = @("100"),
    [int]$Repeats = 1,
    [int]$QueueMaxLength = 100,
    [int]$DurationSeconds = 60,
    [string]$Out = "",
    [string]$OrderCpus = ""
)
$ErrorActionPreference = "Continue"
$env:TEMP = 'E:\Agent_Memory\DACNTT\tmp'; $env:TMP = $env:TEMP
$project = "flashsale-bp"; $port = 18080; $promPort = 15792
$clone = "E:\Agent_Memory\DACNTT\scratch\bp-$Version"
if (-not $Out) { $Out = "E:\Agent_Memory\DACNTT\tmp\w15bp\out-$Version" }
"== $Version clone $(Get-Date -Format HH:mm:ss)"
if (Test-Path $clone) { Remove-Item -Recurse -Force $clone }
git clone -q --branch main-test-bug-fix D:\DACNTT $clone
Set-Location $clone
if ($Version -eq "frozen") {
    git checkout -q 9d00beafdef229418112abce26a48899e4b04ba8
} else {
    robocopy D:\DACNTT\src\FlashSale.ProcessWorker (Join-Path $clone "src\FlashSale.ProcessWorker") /E /XD bin obj Logs /NFL /NDL /NJH /NJS | Out-Null
}
"commit $(git rev-parse HEAD); worker files differing from HEAD: $((git status --porcelain src/FlashSale.ProcessWorker | Measure-Object).Count)"
$pfx = Join-Path $clone "infra\openiddict.pfx"
if (-not (Test-Path $pfx)) { & dotnet dev-certs https -v -ep $pfx -p "99426be9-e087-4c7d-b9cb-566835df936d" 2>&1 | Out-Null }
$envText = (Get-Content infra\ec2.env.example -Raw) -replace 'CHANGE_ME_[A-Z_]+', 'bp_local_dev'
$envText += "`nNGINX_HOST_PORT=$port`n"
Set-Content infra\bp.env $envText -Encoding ASCII
$override = Join-Path $env:TEMP "flashsale-bp-override.yml"
@"
services:
  rabbitmq:
    ports:
      - "${promPort}:15692"
"@ | Set-Content $override -Encoding ASCII
# optional: slow Order Service down so its queues fill (the 2-vCPU EC2 host does this by itself)
if ($OrderCpus) { Add-Content $override "  order-service:`n    cpus: $OrderCpus" -Encoding ASCII }
"override:"; Get-Content $override
function Compose([string[]]$a) { & docker compose -p $project --env-file infra\bp.env -f infra\docker-compose.ec2.yml -f $override @a 2>&1 | ForEach-Object { "$_" } }
$exit = 1
try {
    "== build + up $(Get-Date -Format HH:mm:ss)"
    Compose @("build") | Select-Object -Last 1
    Compose @("up", "-d") | Select-Object -Last 1
    for ($i = 0; $i -lt 180; $i++) {
        $ok = @("postgres", "redis", "rabbitmq") | ForEach-Object { (docker inspect -f '{{.State.Health.Status}}' "$project-$_-1" 2>$null) -eq "healthy" }
        if (-not ($ok -contains $false)) { break }; Start-Sleep 2
    }
    if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
    $common = @{ Project = $project; EnvFile = "infra/bp.env"; ExtraComposeFile = $override; BackendPort = $port
        RabbitMqMetricsUrl = "http://localhost:$promPort/metrics"; Repeats = $Repeats; DurationSeconds = $DurationSeconds
        QueueMaxLength = $QueueMaxLength }
    "== C3 at $($Rates -join ',')/s, queue bound $QueueMaxLength $(Get-Date -Format HH:mm:ss)"
    & .\scripts\run-matrix.ps1 @common -Configs C3 -Rates $Rates -OutDir $Out *>&1 | ForEach-Object { "   $_" }
    $exit = $LASTEXITCODE
    # per run: Worker dead letters, back-pressure waits, reconciliation re-triggers, from the collector samples
    foreach ($m in Get-ChildItem $Out -Recurse -Filter manifest.json) {
        $j = Get-Content -Raw $m.FullName | ConvertFrom-Json
        $s = Join-Path $m.DirectoryName "samples.csv"
        $span = @{}
        if (Test-Path $s) {
            foreach ($r in Import-Csv $s) {
                $k = "$($r.name)|$($r.labels)"
                $v = 0.0; if (-not [double]::TryParse($r.value, [ref]$v)) { continue }
                if (-not $span.ContainsKey($k)) { $span[$k] = @($v, $v) } else { $span[$k][1] = $v }
            }
        }
        function Delta([string]$pattern) { $t = 0.0; foreach ($k in $span.Keys) { if ($k -match $pattern) { $t += $span[$k][1] - $span[$k][0] } }; return $t }
        # local runs pass no service metrics URLs, so the Worker's dead letters are read
        # from its DLQ depth (the collector samples every queue)
        $dlq = 0; if (Test-Path $s) { foreach ($r in Import-Csv $s) { if ($r.name -eq 'messages_ready' -and $r.labels -eq 'queue=ProcessWorker.StockReserved.dlq') { $v = 0.0; if ([double]::TryParse($r.value, [ref]$v) -and $v -gt $dlq) { $dlq = $v } } } }
        $dl = $dlq
        $bp = Delta '^flashsale_consumer_backpressure_waits_total\|'
        $rec = Delta '^flashsale_reconciliation_retriggers_total\|'
        # read straight from the stack, which is still up after the last run
        $rec = (("SELECT count(*) - count(DISTINCT `"OrderId`") FROM order_service.outbox_events WHERE `"EventType`" = 'OrderPlaced';") | docker exec -i "$project-postgres-1" psql -U flashsale -d flashsale -At -f - 2>&1 | Out-String).Trim()
        $bp = ((docker exec "$project-nginx-1" curl -s http://process-worker:8080/metrics 2>$null) | Select-String '^flashsale_consumer_backpressure_waits_total\{' | ForEach-Object { ($_.Line -split ' ')[-1] }) -join ','
        if (-not $bp) { $bp = "not exported" }
        # which state each re-triggered order was stuck in, from Order Service's log
        $stuck = @(docker logs "$project-order-service-1" 2>&1 | Select-String 'Reconciliation: order \S+ stuck in (\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ','
        "   reconciliation by state: $(if ($stuck) { $stuck } else { 'none' })"
        "RUN $Version $($j.config) $($j.requested_per_s)/s status=$($j.status) accepted=$($j.post.db_accepted) drain=$($j.post.drain_seconds)s validator=$($j.post.validator_exit) worker_dead_letters=$dl backpressure_waits=$bp reconciliation_retriggers=$rec"
    }
}
finally {
    "== down $(Get-Date -Format HH:mm:ss)"
    Compose @("down", "-v") | Select-Object -Last 1
    Remove-Item $override -Force -ErrorAction SilentlyContinue
}
"Exit code: $exit"
exit $exit
