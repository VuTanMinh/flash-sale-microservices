# ============================================================
# Flash-Sale Microservices  -  Onboarding setup (Week 0 tooling)
#
# For ANY workmate/teammate setting up a fresh Windows machine for this
# project. Installs/verifies everything FLASHSALE_EXECUTION_CHECKLIST.md's
# "Week 0  -  Tooling prerequisites" section requires, and nothing project-
# specific beyond that (no repo scaffolding, no ABP service generation,
# no infra provisioning  -  that's setup-week1.ps1's job, run this first).
#
# Idempotent: safe to re-run. Every step checks current state before
# acting, so re-running after a partial run only does what's still missing.
#
# This script is NOT executed for you  -  run it yourself:
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1
# or paste sections into your terminal one at a time if you'd rather
# review each step before it runs.
# ============================================================

param(
    # ABP's supported .NET version changes across releases  -  check
    # https://abp.io/docs before trusting this default on a new machine.
    [string]$DotNetSdkWingetId = "Microsoft.DotNet.SDK.10",
    [string]$JMeterVersion = "5.6.3",
    [string]$ToolsRoot = "D:\tools",
    [string]$GitHubEmail = $null,
    [string]$GitHubName = $null
)

$ErrorActionPreference = "Stop"
$results = @()

function Write-Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }
function Add-Result($name, $status, $detail) {
    $script:results += [PSCustomObject]@{ Item = $name; Status = $status; Detail = $detail }
}
function Test-CommandExists($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# --- 1. Git + identity ---
Write-Step "Git"
if (Test-CommandExists git) {
    $gitVersion = (git --version)
    Add-Result "Git" "OK" $gitVersion

    $existingName = git config --global user.name
    $existingEmail = git config --global user.email
    if ($existingName -and $existingEmail) {
        Add-Result "Git identity" "OK" "$existingName <$existingEmail>"
    } else {
        if ($GitHubName -and $GitHubEmail) {
            git config --global user.name $GitHubName
            git config --global user.email $GitHubEmail
            Add-Result "Git identity" "SET" "$GitHubName <$GitHubEmail>"
        } else {
            Add-Result "Git identity" "MISSING" "Run: git config --global user.name `"Your Name`"; git config --global user.email `"you@example.com`" (or re-run this script with -GitHubName / -GitHubEmail)"
        }
    }
} else {
    Add-Result "Git" "MISSING" "winget install Git.Git, then re-run this script"
}

# --- 2. SSH key for GitHub ---
Write-Step "SSH key"
$sshDir = "$env:USERPROFILE\.ssh"
$sshKey = "$sshDir\id_ed25519"
if (Test-Path $sshKey) {
    Add-Result "SSH key" "OK" $sshKey
} else {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $keyEmail = if ($GitHubEmail) { $GitHubEmail } else { git config --global user.email }
    if (-not $keyEmail) { $keyEmail = "you@example.com" }
    if (Test-CommandExists ssh-keygen) {
        ssh-keygen -t ed25519 -C $keyEmail -f $sshKey -N '""' | Out-Null
        Get-Content "$sshKey.pub" | Set-Clipboard
        Add-Result "SSH key" "GENERATED" "Public key copied to clipboard  -  add it at https://github.com/settings/keys, then verify with: ssh -T git@github.com"
    } else {
        Add-Result "SSH key" "MISSING" "ssh-keygen not found (should ship with Git for Windows)  -  install Git first"
    }
}

# --- 3. .NET SDK + ABP CLI ---
Write-Step ".NET SDK + ABP CLI"
if (Test-CommandExists dotnet) {
    Add-Result ".NET SDK" "OK" (dotnet --version)
} else {
    Write-Host "Installing .NET SDK ($DotNetSdkWingetId) via winget..."
    winget install --id $DotNetSdkWingetId --silent --accept-package-agreements --accept-source-agreements
    Add-Result ".NET SDK" "INSTALLED" "Re-open your terminal, then verify: dotnet --version"
}

if (Test-CommandExists abp) {
    Add-Result "ABP CLI" "OK" (abp --version)
} elseif (Test-CommandExists dotnet) {
    dotnet tool install -g Volo.Abp.Cli
    Add-Result "ABP CLI" "INSTALLED" "Verify: abp --version"
} else {
    Add-Result "ABP CLI" "SKIPPED" ".NET SDK not available yet  -  re-run this script after it's installed"
}

# --- 4. Docker Desktop ---
Write-Step "Docker Desktop"
if (Test-CommandExists docker) {
    Add-Result "Docker CLI" "OK" (docker --version)
    try {
        docker info *> $null
        Add-Result "Docker daemon" "RUNNING" "docker run hello-world to fully verify"
    } catch {
        $dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $dockerExe) {
            Write-Host "Docker Desktop installed but not running  -  starting it..."
            Start-Process $dockerExe
            Add-Result "Docker daemon" "STARTING" "Give it ~30-60s, then verify: docker run hello-world"
        } else {
            Add-Result "Docker daemon" "NOT RUNNING" "Start Docker Desktop manually"
        }
    }
} else {
    Write-Host "Installing Docker Desktop via winget..."
    winget install --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
    Add-Result "Docker Desktop" "INSTALLED" "Restart may be required. After first launch: Settings > Resources > give it >=4 CPU / 8GB RAM. Keep builds in native PowerShell on D:\, not inside a WSL2 shell, to avoid cross-filesystem I/O slowdowns."
}

# --- 5. Terraform (used by setup-week1.ps1 for local infra provisioning) ---
Write-Step "Terraform"
if (Test-CommandExists terraform) {
    Add-Result "Terraform" "OK" (terraform --version | Select-Object -First 1)
} else {
    Write-Host "Installing Terraform via winget..."
    winget install --id Hashicorp.Terraform --silent --accept-package-agreements --accept-source-agreements
    Add-Result "Terraform" "INSTALLED" "Verify: terraform --version"
}

# --- 6. Apache JMeter ---
Write-Step "Apache JMeter"
$jmeterDir = "$ToolsRoot\apache-jmeter-$JMeterVersion"
if (Test-Path "$jmeterDir\bin\jmeter.bat") {
    Add-Result "JMeter" "OK" $jmeterDir
} else {
    New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
    $zipPath = "$ToolsRoot\apache-jmeter-$JMeterVersion.zip"
    $url = "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-$JMeterVersion.zip"
    Write-Host "Downloading JMeter $JMeterVersion from $url ..."
    Invoke-WebRequest -Uri $url -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $ToolsRoot -Force
    Remove-Item $zipPath
    if (Test-Path "$jmeterDir\bin\jmeter.bat") {
        Add-Result "JMeter" "INSTALLED" "$jmeterDir  -  open bin\jmeter.bat once to confirm the GUI launches"
    } else {
        Add-Result "JMeter" "FAILED" "Extracted but bin\jmeter.bat not found at expected path  -  check $ToolsRoot manually"
    }
}

# --- 7. VS Code extensions ---
Write-Step "VS Code extensions"
if (Test-CommandExists code) {
    $extensions = @(
        "ms-dotnettools.csdevkit",
        "ms-azuretools.vscode-docker",
        "bierner.markdown-mermaid",
        "james-yu.latex-workshop"
    )
    $installed = code --list-extensions
    foreach ($ext in $extensions) {
        if ($installed -contains $ext) {
            Add-Result "VS Code: $ext" "OK" ""
        } else {
            code --install-extension $ext --force | Out-Null
            Add-Result "VS Code: $ext" "INSTALLED" ""
        }
    }
} else {
    Add-Result "VS Code CLI" "MISSING" "Install VS Code, then run this script again (or install extensions manually: C# Dev Kit, Docker, Markdown Preview Mermaid Support, LaTeX Workshop)"
}

# --- Summary ---
Write-Step "Summary"
$results | Format-Table -AutoSize -Wrap

$blocking = $results | Where-Object { $_.Status -in @("MISSING", "FAILED") }
if ($blocking) {
    Write-Host "`nItems needing your attention before Week 1 work continues:" -ForegroundColor Yellow
    $blocking | ForEach-Object { Write-Host " - $($_.Item): $($_.Detail)" -ForegroundColor Yellow }
} else {
    Write-Host "`nAll Week 0 tooling checks passed." -ForegroundColor Green
}
