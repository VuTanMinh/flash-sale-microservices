# ============================================================
# Creates src/FlashSale.OrderService/openiddict.pfx if it is missing.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\create-openiddict-cert.ps1
#
# Outside the Development environment, ABP's OpenIddict module loads its
# signing/encryption certificate from openiddict.pfx (OrderServiceModule).
# *.pfx is git-ignored, so a fresh clone does not have it and Order Service
# stops at startup with "Signing Certificate couldn't found: openiddict.pfx".
# This uses the ABP-documented `dotnet dev-certs` command with the
# passphrase read from appsettings.json (AuthServer:CertificatePassPhrase) --
# the same key OrderServiceModule reads, so the two can never drift.
# Local/experiment use only.
# ============================================================
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pfx = Join-Path $repoRoot "src\FlashSale.OrderService\openiddict.pfx"
$appSettings = Join-Path $repoRoot "src\FlashSale.OrderService\appsettings.json"
$appSettingsJson = Get-Content $appSettings -Raw | ConvertFrom-Json
$passphrase = $appSettingsJson.AuthServer.CertificatePassPhrase
if ([string]::IsNullOrWhiteSpace($passphrase)) {
    Write-Host "AuthServer:CertificatePassPhrase is missing in $appSettings" -ForegroundColor Red
    exit 1
}

if (Test-Path $pfx) {
    Write-Host "openiddict.pfx already exists: $pfx"
    exit 0
}
dotnet dev-certs https -v -ep $pfx -p $passphrase | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pfx)) {
    Write-Host "Could not create $pfx" -ForegroundColor Red
    exit 1
}
Write-Host "Created $pfx" -ForegroundColor Green
