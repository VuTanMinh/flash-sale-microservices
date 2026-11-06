# Local dry run for the supplementary EC2 session (docs/week14-supplementary-runs.md).
# A fresh clone of the committed HEAD on E:, a scratch Compose stack set up the way
# verify-ec2-stack.ps1 does (project flashsale-ec2v, port 18080), then run-matrix.ps1
# with CLI values only: a sell-out cell for C1, C2 and C3 (-Stock 1000, 100/s for
# 20 s = about 2000 requests) and C1 and C2 at 400/s. The stack is removed at the end.
param([string]$Clone = "E:\Agent_Memory\DACNTT\scratch\supp-dry", [string]$Out = "E:\Agent_Memory\DACNTT\tmp\w15supp\out")
$ErrorActionPreference = "Continue"
$env:TEMP = 'E:\Agent_Memory\DACNTT\tmp'; $env:TMP = $env:TEMP
$project = "flashsale-ec2v"; $port = 18080; $promPort = 15792
"== clone $(Get-Date -Format HH:mm:ss)"
if (Test-Path $Clone) { Remove-Item -Recurse -Force $Clone }
git clone -q --branch main-test-bug-fix D:\DACNTT $Clone
Set-Location $Clone
# the git-ignored certificate, made the way verify-ec2-stack.ps1 makes it
$pfx = Join-Path $Clone "infra\openiddict.pfx"
if (-not (Test-Path $pfx)) { & dotnet dev-certs https -v -ep $pfx -p "99426be9-e087-4c7d-b9cb-566835df936d" 2>&1 | Out-Null }
"certificate present: $(Test-Path $pfx)"
"commit $(git rev-parse HEAD)"
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
ORDER_RATE=1000r/s
ORDER_BURST=500
NGINX_HOST_PORT=$port
PG_MAX_CONNECTIONS=200
"@ | Set-Content infra\ec2-verify.env -Encoding ASCII
$override = Join-Path $env:TEMP "flashsale-ec2v-override.yml"
@"
services:
  rabbitmq:
    ports:
      - "${promPort}:15692"
"@ | Set-Content $override -Encoding ASCII
function Compose([string[]]$a) { & docker compose -p $project --env-file infra\ec2-verify.env -f infra\docker-compose.ec2.yml -f $override @a 2>&1 | ForEach-Object { "$_" } }
$exit = 1
try {
    "== build + up $(Get-Date -Format HH:mm:ss)"
    Compose @("build") | Select-Object -Last 2
    Compose @("up", "-d") | Select-Object -Last 2
    for ($i = 0; $i -lt 180; $i++) {
        $ok = @("postgres", "redis", "rabbitmq") | ForEach-Object { (docker inspect -f '{{.State.Health.Status}}' "$project-$_-1" 2>$null) -eq "healthy" }
        if (-not ($ok -contains $false)) { break }; Start-Sleep 2
    }
    if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
    $common = @{ Project = $project; EnvFile = "infra/ec2-verify.env"; ExtraComposeFile = $override; BackendPort = $port
        RabbitMqMetricsUrl = "http://localhost:$promPort/metrics"; Repeats = 1; DurationSeconds = 20 }
    "== sell-out: C1, C2, C3 at 100/s with -Stock 1000 $(Get-Date -Format HH:mm:ss)"
    & .\scripts\run-matrix.ps1 @common -Configs C1, C2, C3 -Rates 100 -Stock 1000 -OutDir (Join-Path $Out "sellout") *>&1 | ForEach-Object { "   $_" }
    $e1 = $LASTEXITCODE
    "== C1 and C2 at 400/s (stock default) $(Get-Date -Format HH:mm:ss)"
    & .\scripts\run-matrix.ps1 @common -Configs C1, C2 -Rates 400 -OutDir (Join-Path $Out "rate400") *>&1 | ForEach-Object { "   $_" }
    $e2 = $LASTEXITCODE
    "matrix exits: sellout=$e1 rate400=$e2"
    foreach ($m in Get-ChildItem $Out -Recurse -Filter manifest.json) {
        $j = Get-Content -Raw $m.FullName | ConvertFrom-Json
        $vl = Join-Path $m.DirectoryName "validator.log"
        $checks = if (Test-Path $vl) { (Select-String -Path $vl -Pattern '^\s*[0-9]+b?\.\s.*(PASS|FAIL|NOT APPLICABLE|INCONCLUSIVE)' | ForEach-Object { $_.Line.Trim() }) -join ' | ' } else { "no validator.log" }
        "RUN $($j.config) $($j.requested_per_s)/s stock=$($j.stock) status=$($j.status) achieved=$($j.load.achieved_per_s) 2xx=$($j.load.submissions_2xx) accepted=$($j.post.db_accepted) drain=$($j.post.drain_seconds)s validator=$($j.post.validator_exit)"
        "   $checks"
    }
    $exit = $(if ($e1 -eq 0 -and $e2 -eq 0) { 0 } else { 1 })
}
finally {
    "== down $(Get-Date -Format HH:mm:ss)"
    Compose @("down", "-v") | Select-Object -Last 1
    Remove-Item $override -Force -ErrorAction SilentlyContinue
}
"Exit code: $exit"
exit $exit
