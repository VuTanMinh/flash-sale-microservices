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
# passphrase already in OrderServiceModule. Local/experiment use only.
# ============================================================
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pfx = Join-Path $repoRoot "src\FlashSale.OrderService\openiddict.pfx"
$passphrase = "99426be9-e087-4c7d-b9cb-566835df936d"   # must match OrderServiceModule

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
