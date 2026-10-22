# ============================================================
# TP-L03 + TP-L04 (EC2 half): offline deployment checks (Week 12 boxes 3 and 4).
#
#   powershell -File .\scripts\verify-deployment.ps1 `
#       -TerraformExe E:\terraform_1.16.6_windows_amd64\terraform.exe
#
# Offline checks only -- no AWS account is needed and none of the commands below
# touches AWS. It checks the Terraform (fmt/validate, region, security-group
# rules, forbidden resources, instance types, cpu_credits), that every image in
# both Compose files is pinned, that only Nginx publishes a port in the EC2
# Compose file, that the three Dockerfiles build and the EC2 Compose file passes
# `docker compose config`, and (box 4) that user_data installs git on both hosts,
# PowerShell 7 on the backend and verifies the JMeter SHA-512 before extracting.
#
#   - terraform validate requires `terraform init` to have been run first
#     (Claude runs it); if the provider is missing, that one check fails.
#   - docker build / docker compose config need Docker (no AWS).
#   - the LIVE checks (smoke from the JMeter host; internal ports closed from
#     the JMeter host) are printed at the end but marked NOT RUN until the
#     first `terraform apply`.
# ============================================================
param(
    [string]$TerraformExe = "terraform"
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tfDir = Join-Path $repoRoot "infra\terraform"
$failures = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) {
        Write-Host "PASS  $name" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $name -- $detail" -ForegroundColor Red
        $script:failures++
    }
}

# ---------------------------------------------------------------------------
# Static checks on the Terraform files (no external tools)
# ---------------------------------------------------------------------------
$mainTf = Get-Content -Raw (Join-Path $tfDir "main.tf")
$variablesTf = Get-Content -Raw (Join-Path $tfDir "variables.tf")
$versionsTf = Get-Content -Raw (Join-Path $tfDir "versions.tf")
$allTf = "$mainTf`n$variablesTf`n$versionsTf"

# Region locked to ap-southeast-2: the provider uses var.aws_region, whose
# default is ap-southeast-2.
Check "region is ap-southeast-2 (var.aws_region default)" ($mainTf -match 'region\s*=\s*var\.aws_region' -and $variablesTf -match 'default\s*=\s*"ap-southeast-2"') "provider must use var.aws_region with default ap-southeast-2"

# Every ingress block (no nested braces in this config) must not allow the world.
$ingressBlocks = @([regex]::Matches($mainTf, 'ingress\s*\{[^{}]*\}') | ForEach-Object { $_.Value })
$ingressOpenToWorld = @($ingressBlocks | Where-Object { $_ -match '0\.0\.0\.0/0' })
Check "no 0.0.0.0/0 ingress" ($ingressOpenToWorld.Count -eq 0) "$($ingressOpenToWorld.Count) ingress block(s) allow 0.0.0.0/0"

$sshIngress = @($ingressBlocks | Where-Object { $_ -match '(from_port|to_port)\s*=\s*22' })
Check "no SSH (port 22) ingress" ($sshIngress.Count -eq 0) "$($sshIngress.Count) ingress block(s) open port 22"

# Forbidden AWS resources: eip, nat gateway, any load balancer, db instance, IAM.
$forbidden = @([regex]::Matches($allTf, 'resource\s+"aws_(eip|nat_gateway|lb|alb|nlb|db_instance|iam_\w+)"') | ForEach-Object { $_.Value })
Check "no forbidden AWS resources (eip/nat/lb/db/iam)" ($forbidden.Count -eq 0) ($forbidden -join ', ')

# Instance types: the two defaults must be in the allowed list, and the
# validation blocks must list exactly the allowed types.
$allowed = @("t3.micro", "t3.small", "t4g.micro", "t4g.small", "c7i-flex.large", "m7i-flex.large")
$typeDefaults = @([regex]::Matches($variablesTf, 'default\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '^(t[0-9]|m[0-9]|c[0-9])' })
$badDefaults = @($typeDefaults | Where-Object { $allowed -notcontains $_ })
Check "instance_type defaults are in the allowed list" ($badDefaults.Count -eq 0) "bad: $($badDefaults -join ', ')"
Check "instance_type validation lists only the allowed types" ($variablesTf -match 'contains\(\["t3\.micro", "t3\.small", "t4g\.micro", "t4g\.small", "c7i-flex\.large", "m7i-flex\.large"\]') "validation block missing or wrong"

# cpu_credits = "standard" for t3/t4g (burstable credits).
Check 'cpu_credits = "standard" present' ($mainTf -match 'cpu_credits\s*=\s*"standard"') "expected cpu_credits standard for t3/t4g"

# Both instances self-terminate as a forgotten-session safety net: each has
# instance_initiated_shutdown_behavior = "terminate" and a `shutdown -h +` line
# in its user_data.
$terminateBehavior = @([regex]::Matches($mainTf, 'instance_initiated_shutdown_behavior\s*=\s*"terminate"') | ForEach-Object { $_.Value })
$shutdownTimer = @([regex]::Matches($mainTf, 'shutdown\s+-h\s+\+') | ForEach-Object { $_.Value })
Check "both instances self-terminate (terminate behavior + shutdown -h + timer)" ($terminateBehavior.Count -eq 2 -and $shutdownTimer.Count -eq 2) "terminate behavior: $($terminateBehavior.Count), shutdown -h + lines: $($shutdownTimer.Count)"

# Week 12 box 4 (EC2 half): the overload run needs git on both hosts (each
# clones the repo), PowerShell 7 on the backend (the collector/extractor run
# there), and a checksum check on the JMeter download.
$gitInstallLines = @([regex]::Matches($mainTf, 'dnf install -y[^\r\n]*\bgit\b') | ForEach-Object { $_.Value })
Check "user_data installs git on both hosts" ($gitInstallLines.Count -ge 2) "git install lines: $($gitInstallLines.Count)"
Check "backend user_data installs PowerShell 7 (pinned)" ($mainTf -match 'powershell-\$\$\{PWSH_VERSION\}-1\.rh\.x86_64\.rpm' -and $mainTf -match 'pwsh --version') "pwsh must be installed on the backend"
Check "JMeter download verifies the SHA-512 from Apache before extracting" ($mainTf -match 'sha512sum -c' -and $mainTf -match '\.sha512') "a truncated archive download must be caught"

# ---------------------------------------------------------------------------
# Image pinning in both Compose files
# ---------------------------------------------------------------------------
function Get-ComposeImages([string]$path) {
    $images = @()
    foreach ($line in (Get-Content $path)) {
        $m = [regex]::Match($line, '^\s*image:\s*([^\s]+)')
        if ($m.Success) { $images += $m.Groups[1].Value }
    }
    return @($images)
}

$localImages = @(Get-ComposeImages (Join-Path $repoRoot "infra\docker-compose.yml"))
$ec2Images = @(Get-ComposeImages (Join-Path $repoRoot "infra\docker-compose.ec2.yml"))
$allImages = @($localImages) + @($ec2Images)
$unpinned = @()
foreach ($img in $allImages) {
    $tag = ($img -split ':')[-1]
    if ($tag -eq 'latest' -or $tag -notmatch '\.') { $unpinned += $img }
}
Check "every Compose image pinned (no latest, full version)" ($unpinned.Count -eq 0) ($unpinned -join ', ')

# Only Nginx publishes a host port in the EC2 Compose file (80:80, once).
$ec2Compose = Get-Content -Raw (Join-Path $repoRoot "infra\docker-compose.ec2.yml")
$portsCount = ([regex]::Matches($ec2Compose, '(?m)^\s*ports:')).Count
$nginxPorts = $ec2Compose -match 'ports:\s*\["80:80"\]'
Check "only Nginx publishes a host port (80) in the EC2 Compose" ($portsCount -eq 1 -and $nginxPorts) "ports blocks: $portsCount"

# ---------------------------------------------------------------------------
# Terraform fmt / validate (need the terraform binary, no AWS)
# ---------------------------------------------------------------------------
$tfOk = $true
try {
    & $TerraformExe version *> $null
    if ($LASTEXITCODE -ne 0) { $tfOk = $false }
} catch {
    $tfOk = $false
}
if ($tfOk) {
    & $TerraformExe "-chdir=$tfDir" fmt -check
    $fmtExit = $LASTEXITCODE
    Check "terraform fmt -check" ($fmtExit -eq 0) "exit $fmtExit"

    & $TerraformExe "-chdir=$tfDir" validate -no-color
    $valExit = $LASTEXITCODE
    Check "terraform validate" ($valExit -eq 0) "exit $valExit (run terraform init first)"
} else {
    Check "terraform available (fmt/validate)" $false "terraform not found at '$TerraformExe'"
}

# ---------------------------------------------------------------------------
# Docker build + compose config (need Docker, no AWS)
# ---------------------------------------------------------------------------
$dockerOk = $true
try {
    docker --version *> $null
    if ($LASTEXITCODE -ne 0) { $dockerOk = $false }
} catch {
    $dockerOk = $false
}
if ($dockerOk) {
    $builds = @(
        @{ Name = "OrderService";     Tag = "flashsale-order-service:10.0" },
        @{ Name = "InventoryService"; Tag = "flashsale-inventory-service:10.0" },
        @{ Name = "ProcessWorker";    Tag = "flashsale-process-worker:10.0" }
    )
    foreach ($b in $builds) {
        $dockerfile = Join-Path $repoRoot "src\FlashSale.$($b.Name)\Dockerfile"
        & docker build -f $dockerfile -t $b.Tag $repoRoot *> $null
        Check "docker build FlashSale.$($b.Name)" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    }

    & docker compose --env-file (Join-Path $repoRoot "infra\ec2.env.example") -f (Join-Path $repoRoot "infra\docker-compose.ec2.yml") config *> $null
    Check "docker compose config (EC2)" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
} else {
    Check "docker available (build/compose config)" $false "docker not found"
}

# ---------------------------------------------------------------------------
# LIVE checks -- not runnable until the first terraform apply
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== LIVE checks (NOT RUN until the first 'terraform apply') ===" -ForegroundColor Yellow
Write-Host "SKIP  smoke from the JMeter host (tests/jmeter/deploy-smoke-test.jmx: POST /api/orders = 201, final state Completed|Rejected)"
Write-Host "SKIP  backend internal ports closed from the JMeter host (5432, 5672, 15672, 6379, 9090, 3000 must not answer; only 80)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
if ($failures -gt 0) {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All offline deployment checks passed." -ForegroundColor Green
exit 0
