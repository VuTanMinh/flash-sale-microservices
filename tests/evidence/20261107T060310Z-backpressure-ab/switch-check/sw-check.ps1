# Live check and Worker switch check on the EC2 backend before the measured runs.
# Prepares both Worker images exactly as scripts/ec2-session.ps1 -Plan backpressure does,
# then for frozen and fix: recreate only the Worker on that image, wait for a consumer,
# record the image id and whether /metrics carries the back-pressure counter's HELP line
# (registered at start-up by the fix only), then one short C3 run (5/s, 20 s, stock 1000)
# through run-matrix with the same override. Finally the Prometheus targets.
param([string]$Out = "E:\Agent_Memory\DACNTT\tmp\w15ab\live2")
$ErrorActionPreference = "Continue"
$env:TEMP = 'E:\Agent_Memory\DACNTT\tmp'; $env:TMP = $env:TEMP
$B = "i-02e9e76e8e3ab2290"; $J = "i-0cf4df00d23fdfd4e"; $ip = "172.31.7.163"
$aws = 'C:\Users\Lenovo\AppData\Local\Programs\Amazon\AWSCLIV2\aws.exe'
$ssm = 'D:\DACNTT\scripts\ec2-ssm-run.ps1'
New-Item -ItemType Directory -Force $Out | Out-Null
function Host-Run([string]$name, [string]$body, [int]$t = 600) {
    $f = Join-Path $Out "$name.sh"; [IO.File]::WriteAllText($f, ("set -uo pipefail`nexec 2>&1`n" + $body).Replace("`r", ""))
    return (@(& powershell -NoProfile -File $ssm -InstanceId $B -ScriptFile $f -TimeoutSeconds $t) -join "`n")
}
$prep = @"
cd /opt/flash-sale-microservices
git fetch -q --tags origin
echo "head `$(git rev-parse HEAD) tag `$(git rev-parse 'w14-official^{commit}')"
docker image inspect flashsale-process-worker:fix >/dev/null 2>&1 || docker tag flashsale-process-worker:10.0 flashsale-process-worker:fix
rm -rf /opt/w14-official; git worktree prune; git worktree add -f /opt/w14-official w14-official >/dev/null 2>&1
docker build -q -t flashsale-process-worker:frozen -f /opt/w14-official/src/FlashSale.ProcessWorker/Dockerfile /opt/w14-official >/dev/null
for v in frozen fix; do printf 'services:\n  process-worker:\n    image: flashsale-process-worker:%s\n' `$v > infra/worker-`$v.yml; done
echo "image frozen `$(docker image inspect -f '{{.Id}}' flashsale-process-worker:frozen)"
echo "image fix `$(docker image inspect -f '{{.Id}}' flashsale-process-worker:fix)"
"@
"== prepare $(Get-Date -Format HH:mm:ss)"
$p = Host-Run "prepare-ab" $prep 1800
($p -split "`n" | Where-Object { $_ -match '^(head|image|status)' }) | ForEach-Object { "   $_" }
Set-Location D:\DACNTT
$res = @()
foreach ($v in "frozen", "fix") {
    "== $v $(Get-Date -Format HH:mm:ss)"
    $sw = @"
cd /opt/flash-sale-microservices
docker tag flashsale-process-worker:$v flashsale-process-worker:10.0
docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml up -d --no-deps process-worker >/dev/null 2>&1
n=0; for i in `$(seq 1 90); do n=`$(docker exec infra-rabbitmq-1 rabbitmqctl -q list_queues name consumers --no-table-headers 2>/dev/null | awk '`$1=="ProcessWorker.StockReserved"{print `$2}'); [ "`${n:-0}" -ge 1 ] && break; sleep 2; done
echo "worker_image `$(docker inspect -f '{{.Image}}' infra-process-worker-1) consumers `${n:-0}"
echo "help_lines `$(docker exec infra-nginx-1 curl -s http://process-worker:8080/metrics | grep -c '^# HELP flashsale_consumer_backpressure_waits_total')"
"@
    $o = Host-Run "switch-$v" $sw 300
    $img = ([regex]::Match($o, 'worker_image (sha256:[0-9a-f]+)')).Groups[1].Value
    $cons = ([regex]::Match($o, 'consumers (\d+)')).Groups[1].Value
    $help = ([regex]::Match($o, 'help_lines (\d+)')).Groups[1].Value
    "   image $img consumers $cons backpressure_help_lines $help"
    $dir = Join-Path $Out $v
    & D:\DACNTT\scripts\run-matrix.ps1 -Transport Ssm -BackendInstance $B -JMeterInstance $J -BackendHost $ip -AwsExe $aws `
        -Configs C3 -Rates 5 -DurationSeconds 20 -Stock 1000 -Repeats 1 -OutDir $dir 2>&1 | ForEach-Object { "   $_" }
    $m = Get-ChildItem $dir -Recurse -Filter manifest.json | Select-Object -First 1 | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json }
    $mimg = "$($m.prepare.images.'infra-process-worker-1')"
    $res += [pscustomobject]@{ v = $v; img = $img; manifest_img = $mimg; help = [int]("0" + $help); status = $m.status; val = $m.post.validator_exit }
    "RESULT $v image=$img manifest_image=$mimg same=$($img -eq $mimg) help=$help status=$($m.status) validator=$($m.post.validator_exit)"
}
$t = Host-Run "targets" "cd /opt/flash-sale-microservices`ndocker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets | grep -o '`"health`":`"[a-z]*`"' | sort | uniq -c" 120
"targets: $((($t -split "`n") | Where-Object { $_ -match 'health' }) -join ' ')"
$fz = $res | Where-Object v -eq frozen; $fx = $res | Where-Object v -eq fix
$ok = $fz.img -and $fx.img -and ($fz.img -ne $fx.img) -and ($fz.img -eq $fz.manifest_img) -and ($fx.img -eq $fx.manifest_img) -and $fz.help -eq 0 -and $fx.help -ge 1 -and $fz.status -eq "PASS" -and $fx.status -eq "PASS" -and $fz.val -eq 0 -and $fx.val -eq 0
"SWITCH CHECK $(if ($ok) { 'PASS' } else { 'FAIL' }): the image id changes, the manifest records it, the back-pressure HELP line is on fix only (marker), both runs PASS"
"Exit code: $(if ($ok) { 0 } else { 1 })"
