# ============================================================
# TP-X09 (Week 13 box 2): the Week 14 freeze manifest, docs/week14-freeze.md,
# matches the repository. Each value in the manifest is read again from the
# file the manifest names as its source and compared; a value is never
# compared with itself. Offline: no Docker, no AWS, no registry.
#
#   powershell -File .\scripts\verify-freeze.ps1
#   powershell -File .\scripts\verify-freeze.ps1 -Manifest <copy.md>   (negative controls)
#
# Check 1 (the frozen commit is the parent of the commit that first wrote its
# SHA into the manifest) needs that manifest change to be committed; before
# that it reports NOT APPLICABLE, never PASS, and the script exits non-zero.
# Re-freezing (moving the frozen commit) therefore works the same way as the
# first freeze: the manifest change that names the new commit must sit
# directly on top of it.
# ============================================================
param([string]$Manifest = "")
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Manifest) { $Manifest = Join-Path $root "docs\week14-freeze.md" }
$failures = 0; $checks = 0; $notApplicable = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    $script:checks++
    if (-not $ok) { $script:failures++ }
    Write-Output "$(if ($ok) { 'PASS' } else { 'FAIL' })  $name$(if ($detail) { " -- $detail" })"
}
function Read([string]$rel) { return (Get-Content -Raw -LiteralPath (Join-Path $root $rel) -Encoding UTF8) }
# SHA-256 of the file with LF line endings, as git stores it, so the hash does not
# depend on how a checkout converts line endings (core.autocrlf).
function Sha256([string]$rel) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $rel))
    $lf = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $bytes.Length; $i++) { if (-not ($bytes[$i] -eq 13 -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 10)) { $lf.Add($bytes[$i]) } }
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash($lf.ToArray())
    return (-join ($h | ForEach-Object { $_.ToString("x2") }))
}
function Strip([string]$v) { return ($v -replace '`', '').Trim() }
# Table rows of the manifest: every "| a | b | c |" line that is not a header rule.
$text = Get-Content -Raw -LiteralPath $Manifest -Encoding UTF8
$rows = @($text -split "`r?`n" | Where-Object { $_ -match '^\|' -and $_ -notmatch '^\|\s*-' } | ForEach-Object {
        , @(($_.Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
    })
function Row([string]$first) {
    $r = @($rows | Where-Object { (Strip $_[0]) -eq $first })
    if ($r.Count -ne 1) { return $null }
    return $r[0]
}
function Cell([string]$first, [int]$i = 1) { $r = Row $first; if ($null -eq $r) { return $null }; return (Strip $r[$i]) }
function Num([string]$s) { $m = [regex]::Match("$s", '-?\d+'); if ($m.Success) { return [int]$m.Value } else { return $null } }

$mainTf = Read "infra\terraform\main.tf"; $varsTf = Read "infra\terraform\variables.tf"; $versTf = Read "infra\terraform\versions.tf"
$lock = Read "infra\terraform\.terraform.lock.hcl"; $envEx = Read "infra\ec2.env.example"; $rm = Read "scripts\run-matrix.ps1"
$compose = Read "infra\docker-compose.ec2.yml"; $jmx = Read "tests\jmeter\workload.jmx"; $extract = Read "scripts\extract-run-metrics.ps1"
function VarDefault([string]$name) { $m = [regex]::Match($varsTf, 'variable\s+"' + $name + '"\s*\{[^}]*?default\s*=\s*"?([^"\r\n]+)"?'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null } }
function EnvVal([string]$name) { $m = [regex]::Match($envEx, '(?m)^' + $name + '=(.*)$'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null } }
function RmDefault([string]$name) { $m = [regex]::Match($rm, '\$' + $name + '\s*=\s*([^\r\n]+?),?\s*$', 'Multiline'); if ($m.Success) { return $m.Groups[1].Value.Trim().TrimEnd(',') } else { return $null } }
function RmList([string]$name) { $v = RmDefault $name; if ($null -eq $v) { return $null }; return (@([regex]::Matches($v, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) -join ',') }

# ---------------------------------------------------------- 1. source
Write-Output "== 1. source"
$frozen = Cell "Frozen source commit"
$sha = [regex]::Match("$frozen", '[0-9a-f]{40}').Value
Check "1: frozen commit is a full 40-hex SHA" ($sha -ne "") "cell='$frozen'"
& git -C $root cat-file -e "$sha^{commit}" 2>$null
Check "1: frozen commit exists in this repository" ($LASTEXITCODE -eq 0 -and $sha) "sha=$sha"
$mrel = (Resolve-Path -LiteralPath $Manifest).Path.Substring($root.Length + 1) -replace '\\', '/'
# The commit that first wrote this SHA into the manifest (the oldest commit whose
# diff adds or removes the string); later fixes to the manifest keep it.
$parent = ""
if ($sha) { $parent = (@(git -C $root log -S $sha --format=%P -- $mrel 2>$null) | Select-Object -Last 1 | Out-String).Trim() }
if (-not $parent) {
    $notApplicable++
    Write-Output "NOT APPLICABLE  1: frozen commit is the parent of the commit that names it in the manifest -- no committed $mrel names it yet"
} else {
    Check "1: frozen commit is the parent of the commit that first named it in the manifest" (($parent -split ' ')[0] -eq $sha) "parent=$parent frozen=$sha"
}
if ($sha) {
    $changed = @(git -C $root diff --name-only $sha HEAD 2>$null | Where-Object { $_ -match '^(src|infra|tests/jmeter|scripts)/' -and $_ -ne 'scripts/verify-freeze.ps1' })
    Check "1: no frozen path (src, infra, tests/jmeter, scripts) changed after the frozen commit" ($changed.Count -eq 0) "changed=$($changed -join ',')"
}

# ---------------------------------------------------------- 2. infrastructure
Write-Output "== 2. infrastructure"
$listed = @{}
foreach ($r in $rows) { $f = Strip $r[0]; if ($f -match '^infra/terraform/') { $listed[$f] = (Strip $r[1]) } }
foreach ($f in @(Get-ChildItem (Join-Path $root "infra\terraform") -Filter *.tf | ForEach-Object { "infra/terraform/$($_.Name)" })) {
    Check "2: $f is listed" ($listed.ContainsKey($f))
}
foreach ($f in $listed.Keys) { Check "2: SHA-256 of $f" ((Sha256 ($f -replace '/', '\')) -eq $listed[$f]) "manifest=$($listed[$f])" }
Check "2: region equals variables.tf" ((Cell "Region") -eq (VarDefault "aws_region")) "manifest=$(Cell 'Region') file=$(VarDefault 'aws_region')"
Check "2: availability zone equals variables.tf" ((Cell "Availability zone") -eq (VarDefault "availability_zone"))
Check "2: backend instance type equals variables.tf" (((Cell "Backend instance type") -split ' ')[0] -eq (VarDefault "backend_instance_type")) "manifest=$(Cell 'Backend instance type')"
Check "2: JMeter instance type equals variables.tf" ((Cell "JMeter instance type") -eq (VarDefault "jmeter_instance_type"))
Check "2: root volume equals variables.tf" ((Num (Cell "Root volume")) -eq (Num (VarDefault "root_volume_size_gb")))
$prov = [regex]::Match((Cell "AWS provider"), '\d+\.\d+\.\d+').Value
Check "2: AWS provider version equals versions.tf and the lock file" ($prov -and $versTf -match ('version\s*=\s*"' + [regex]::Escape($prov) + '"') -and $lock -match ('version\s*=\s*"' + [regex]::Escape($prov) + '"')) "manifest=$prov"
$req = [regex]::Match((Cell "Terraform required"), '>=\s*[\d.]+').Value
Check "2: required Terraform version equals versions.tf" ($req -and $versTf -match ('required_version\s*=\s*"' + [regex]::Escape($req) + '"')) "manifest=$req"

# ---------------------------------------------------------- 3. tools
Write-Output "== 3. tools"
$gj = (Read "global.json" | ConvertFrom-Json).sdk.version
Check "3: .NET SDK equals global.json" (((Cell ".NET SDK") -split ' ')[0] -eq $gj) "manifest=$(Cell '.NET SDK') global.json=$gj"
$rt = Cell ".NET runtime in the images"; $sb = Cell ".NET SDK in the image build"
foreach ($df in @(Get-ChildItem (Join-Path $root "src") -Recurse -Filter Dockerfile | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' })) {
    $d = Get-Content -Raw -LiteralPath $df.FullName
    Check "3: $($df.Directory.Name) Dockerfile uses the listed SDK and runtime images" ($d -match ('FROM\s+' + [regex]::Escape($sb) + '\s') -and $d -match ('FROM\s+' + [regex]::Escape($rt) + '\s')) "sdk=$sb runtime=$rt"
}
$jm = [regex]::Match((Cell "JMeter (JMeter host)"), '\d+\.\d+\.\d+').Value
Check "3: JMeter version equals main.tf JMETER_VERSION" ($jm -and $mainTf -match ('JMETER_VERSION=' + [regex]::Escape($jm))) "manifest=$jm"
Check "3: local JMeter folder exists for that version" (Test-Path ("D:\tools\apache-jmeter-" + $jm))
$dc = Strip (Cell "Docker Compose plugin (backend)")
Check "3: Compose plugin equals main.tf DOCKER_COMPOSE_VERSION" ($dc -and $mainTf -match ('DOCKER_COMPOSE_VERSION=' + [regex]::Escape($dc))) "manifest=$dc"
$ps = Strip (Cell "PowerShell (backend)")
Check "3: PowerShell equals main.tf PWSH_VERSION" ($ps -and $mainTf -match ('PWSH_VERSION=' + [regex]::Escape($ps))) "manifest=$ps"
Check "3: Java package named in main.tf" ($mainTf -match 'java-17-amazon-corretto-headless' -and (Cell "Java (JMeter host)") -match 'java-17-amazon-corretto-headless')

# ---------------------------------------------------------- 4. images
Write-Output "== 4. images"
$composeImages = @([regex]::Matches($compose, '(?m)^\s*image:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^flashsale-' } | Sort-Object -Unique)
$imageRows = @{}
foreach ($r in $rows) { $c0 = Strip $r[0]; if ($r.Count -ge 2 -and (Strip $r[1]) -match '^sha256:') { $imageRows[(($c0 -split ' ')[0])] = (Strip $r[1]) } }
foreach ($i in $composeImages) { Check "4: compose image $i has a digest row" ($imageRows.ContainsKey($i)) }
foreach ($k in $imageRows.Keys) {
    Check "4: $k is a compose image or a Dockerfile base image" ($composeImages -contains $k -or $k -eq $sb -or $k -eq $rt)
    Check "4: $k digest is sha256 hex" ($imageRows[$k] -match '^sha256:[0-9a-f]{64}$') "digest=$($imageRows[$k])"
}

# ---------------------------------------------------------- 5. workload
Write-Output "== 5. workload"
Check "5: -Rates default is 50, 100, 200" ((RmList "Rates") -eq "50,100,200") "file=$(RmList 'Rates')"
Check "5: -Configs default is C1 to C4" ((RmList "Configs") -eq "C1,C2,C3,C4") "file=$(RmList 'Configs')"
Check "5: -Replicas default is 1, 2, 4" ((RmList "Replicas") -eq "1,2,4") "file=$(RmList 'Replicas')"
Check "5: -DurationSeconds default equals the manifest (60 s)" ((Num (RmDefault "DurationSeconds")) -eq (Num (Cell "Load per run"))) "file=$(RmDefault 'DurationSeconds') manifest=$(Cell 'Load per run')"
Check "5: -Repeats default equals the manifest (3)" ((Num (RmDefault "Repeats")) -eq (Num (Cell "Repeats"))) "file=$(RmDefault 'Repeats')"
$prodCell = Cell "Product"
Check "5: -Product and -Stock defaults equal the manifest" ($prodCell -match ([regex]::Escape(((RmDefault "Product") -replace '"', ''))) -and ($prodCell -replace ',', '') -match ("stock " + (RmDefault "Stock"))) "file=$(RmDefault 'Product') $(RmDefault 'Stock') manifest=$prodCell"
Check "5: open-loop mode is the plan's -Jmode the driver passes" ($rm -match '-Jmode=open' -and (Cell "Plan") -match '-Jmode=open')
Check "5: workload.jmx keys come from __UUID()" ($jmx -match '__UUID\(\)')
Check "5: the product CSV is recycled" ($jmx -match 'name="recycle">true<')
Check "5: pacing is a Constant Throughput Timer" ($jmx -match 'ConstantThroughputTimer')
Check "5: the plan has no seed property" ($jmx -notmatch '(?i)seed')

# ---------------------------------------------------------- 6. worker
Write-Output "== 6. worker"
$delay = Num (Cell "Processing delay")
$wApp = Read "src\FlashSale.ProcessWorker\appsettings.json"; $wOpt = Read "src\FlashSale.ProcessWorker\Messaging\ProcessingOptions.cs"
Check "6: Worker delay equals appsettings.json" ($wApp -match ('"DelayMilliseconds":\s*' + $delay + '\b')) "manifest=$delay"
Check "6: Worker delay equals the ProcessingOptions default" ($wOpt -match ('DelayMilliseconds\s*\{\s*get;\s*set;\s*\}\s*=\s*' + $delay + ';'))
Check "6: Worker concurrency equals ec2.env.example" ((Num (Cell "Worker concurrency")) -eq (Num (EnvVal "PROCESSING_MAX_CONCURRENCY")))
Check "6: Worker prefetch equals ec2.env.example" ((Num (Cell "Worker prefetch")) -eq (Num (EnvVal "WORKER_PREFETCH")))

# ---------------------------------------------------------- 7. limits
Write-Output "== 7. limits"
foreach ($r in $rows) {
    $src = Strip $r[$r.Count - 1]
    $m = [regex]::Match($src, 'infra/ec2\.env\.example,\s*(?:`)?([A-Z_]+)')
    if ($m.Success -and $src -notmatch 'run-matrix') {
        $name = $m.Groups[1].Value
        Check "7: $(Strip $r[0]) equals ec2.env.example $name" ((Num (Strip $r[1])) -eq (Num (EnvVal $name))) "manifest=$(Strip $r[1]) file=$(EnvVal $name)"
    }
}
Check "7: gateway (C3, C4) equals the run-matrix ShedOrderRate/Burst and ec2.env.example" ((Cell "Gateway rate limit (C3, C4)") -match ('^' + (Num ((RmDefault "ShedOrderRate") -replace '"', '')) + ' requests/s, burst ' + ((RmDefault "ShedOrderBurst") -replace '"', '') + '$') -and (EnvVal "ORDER_RATE") -eq ((RmDefault "ShedOrderRate") -replace '"', '') -and (EnvVal "ORDER_BURST") -eq ((RmDefault "ShedOrderBurst") -replace '"', '')) "manifest=$(Cell 'Gateway rate limit (C3, C4)')"
Check "7: open gateway equals the run-matrix OpenOrderRate/Burst" ((Cell "Gateway for C1, C2") -match ('^' + (Num ((RmDefault "OpenOrderRate") -replace '"', '')) + ' requests/s, burst ' + ((RmDefault "OpenOrderBurst") -replace '"', '') + ' '))
Check "7: queue bound equals the run-matrix QueueMaxLength default" ((Num (Cell "Queue bound (C3, C4)")) -eq (Num (RmDefault "QueueMaxLength")))
Check "7: the bound overflows with reject-publish" ((Read "scripts\set-queue-bounds.ps1") -match 'overflow\s*=\s*"reject-publish"' -and (Cell "Queue bound (C3, C4)") -match 'reject-publish')
$ladder = @{
    "src\FlashSale.ProcessWorker\Messaging\StockReservedConsumer.cs" = "Worker"
    "src\FlashSale.OrderService\Messaging\StockResultConsumer.cs" = "handler"
    "src\FlashSale.OrderService\Messaging\OrderProcessingStartedConsumer.cs" = "handler"
    "src\FlashSale.OrderService\Messaging\OrderProcessedConsumer.cs" = "handler"
    "src\FlashSale.InventoryService\Messaging\OrderPlacedConsumer.cs" = "handler"
    "src\FlashSale.OrderService\Messaging\OutboxPublisherWorker.cs" = "outbox"
    "src\FlashSale.InventoryService\Messaging\OutboxPublisherWorker.cs" = "outbox"
}
$attempts = Num (Cell "Worker publish attempts")
foreach ($f in $ladder.Keys) {
    $c = Read $f
    $rd = [regex]::Match($c, 'RetryDelays\s*=\s*\[(.*?)\];', 'Singleline').Groups[1].Value
    $secs = (@([regex]::Matches($rd, 'FromSeconds\((\d+)\)') | ForEach-Object { $_.Groups[1].Value }) -join '/')
    Check "7: $(Split-Path $f -Leaf) ($($ladder[$f])) retries 1/2/4 s with $attempts attempts" ($secs -eq "1/2/4" -and $c -match ('MaxAttempts\s*=\s*' + $attempts + ';')) "delays=$secs"
}
foreach ($f in "src\FlashSale.OrderService\Messaging\OrderProcessedConsumer.cs", "src\FlashSale.OrderService\Messaging\OrderProcessingStartedConsumer.cs") {
    $rq = [regex]::Match((Read $f), 'RequeueDelays\s*=\s*\[(.*?)\];', 'Singleline').Groups[1].Value
    $secs = (@([regex]::Matches($rq, 'FromSeconds\((\d+)\)') | ForEach-Object { $_.Groups[1].Value }) -join '/')
    Check "7: $(Split-Path $f -Leaf) delayed requeue is 2/4/8 s" ($secs -eq "2/4/8" -and (Cell "Delayed requeue, early completion") -match '2/4/8') "delays=$secs"
}
$ro = Read "src\FlashSale.OrderService\Messaging\ReconciliationOptions.cs"; $oa = Read "src\FlashSale.OrderService\appsettings.json"
$ra = Num (Cell "Reconciliation attempts"); $rp = Num (Cell "Reconciliation poll"); $rc = Num (Cell "Reconciliation, Confirmed or Processing")
Check "7: reconciliation attempts equal ReconciliationOptions and appsettings.json" ($ro -match ('MaxAttempts\s*\{\s*get;\s*set;\s*\}\s*=\s*' + $ra + ';') -and $oa -match ('"MaxAttempts":\s*' + $ra + '\b')) "manifest=$ra"
Check "7: reconciliation poll equals ReconciliationOptions" ($ro -match ('PollIntervalSeconds\s*\{\s*get;\s*set;\s*\}\s*=\s*' + $rp + ';')) "manifest=$rp"
Check "7: Confirmed/Processing timeout equals appsettings.json" ($oa -match ('"ProcessingStuckTimeoutSeconds":\s*' + $rc + '\b')) "manifest=$rc"
$pf = Num (Cell "Consumer prefetch (Order, Inventory)")
foreach ($f in "src\FlashSale.OrderService\Messaging\RabbitMqOptions.cs", "src\FlashSale.InventoryService\Messaging\RabbitMqOptions.cs") {
    Check "7: $f PrefetchCount default equals the manifest" ((Read $f) -match ('PrefetchCount\s*\{\s*get;\s*set;\s*\}\s*=\s*' + $pf + ';')) "manifest=$pf"
}
Check "7: Outbox publisher batch 50 in both services" ((Read "src\FlashSale.OrderService\Messaging\OutboxPublisherWorker.cs") -match 'BatchSize\s*=\s*50;' -and (Read "src\FlashSale.InventoryService\Messaging\OutboxPublisherWorker.cs") -match 'BatchSize\s*=\s*50;' -and (Cell "Outbox publisher retries (both services)") -match 'batch 50')

# ---------------------------------------------------------- 8. metrics
Write-Output "== 8. metrics"
Check "8: percentiles are nearest-rank (Ceiling) in the extractor and the driver" ($extract -match 'percentile_method = "nearest-rank"' -and $extract -match 'Math\]::Ceiling' -and $rm -match 'Math\]::Ceiling\(\$p / 100')
Check "8: dead letters read flashsale_consumer_dead_lettered_total alone" ($extract -match '\$cDlq = CategoryIncrease @\("flashsale_consumer_dead_lettered_total"\)')
Check "8: retries, duplicates and reconciliations read the named metrics" ($extract -match '\$cRetries = CategoryIncrease @\("flashsale_consumer_retries_total"\)' -and $extract -match '\$cDups = CategoryIncrease @\("flashsale_consumer_duplicates_total"\)' -and $extract -match '\$cRecon = CategoryIncrease @\("flashsale_reconciliation_retriggers_total", "flashsale_reconciliation_given_up_total"\)')
Check "8: achieved rate is (count - 1) / span in the driver" ($rm -match '\(\$ts\.Count - 1\) / \$span')
Check "8: drain waits for orders and both Outboxes" ($rm -match "NOT IN \('Completed','Rejected'\)" -and $rm -match 'order_service\.outbox_events' -and $rm -match 'inventory_service\.outbox_events')

Write-Output ""
if ($failures -gt 0) { Write-Output "$failures of $checks check(s) failed."; exit 1 }
if ($notApplicable -gt 0) { Write-Output "All $checks checks passed, but $notApplicable check is NOT APPLICABLE: commit the manifest and run again."; exit 2 }
Write-Output "All $checks checks passed: docs/week14-freeze.md matches the repository."
exit 0
