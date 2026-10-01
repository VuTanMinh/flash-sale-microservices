# ============================================================
# Starts Order Service in the background for local checks and waits until it
# answers HTTP. Writes the process id to $env:TEMP\order-service-<Port>.pid
# so the same script can stop exactly that process later (-Stop).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\start-order-service.ps1 -DbPort 55432 -Port 5100 -NoBroker
#   powershell -ExecutionPolicy Bypass -File .\scripts\start-order-service.ps1 -Port 5100 -Stop
#
# -NoBroker points RabbitMQ at an unused port so test orders are never
# published into a shared broker (the Outbox simply keeps them unpublished).
# Do not pipe this script's output (e.g. | Out-Null): the service inherits
# the pipe, so the pipeline would wait until the service exits.
# ============================================================
param(
    [int]$Port = 5100,
    [int]$DbPort = 55432,
    [switch]$NoBroker,
    [switch]$Stop
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pidFile = Join-Path $env:TEMP "order-service-$Port.pid"

if ($Stop) {
    if (Test-Path $pidFile) {
        $p = [int](Get-Content $pidFile)
        # Only the tree this script started: dotnet run -> service exe.
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$p" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        [IO.File]::Delete($pidFile)
        Write-Host "Stopped Order Service on port $Port."
    }
    exit 0
}

$env:ConnectionStrings__Default = "Host=localhost;Port=$DbPort;Database=flashsale;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"
$env:ASPNETCORE_URLS = "http://localhost:$Port"
if ($NoBroker) { $env:RabbitMQ__Connections__Default__Port = "5679" }
$log = Join-Path $env:TEMP "order-service-$Port.log"
$svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" `
    -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.OrderService") `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
$svc.Id | Set-Content $pidFile
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    if ($svc.HasExited) { break }
    try { Invoke-WebRequest -UseBasicParsing "http://localhost:$Port/api/orders/00000000-0000-0000-0000-000000000000" -TimeoutSec 3 -ErrorAction Stop | Out-Null; break }
    catch { if ($_.Exception.Response) { Write-Host "Order Service is up on port $Port (log: $log)."; exit 0 } }
}
Write-Host "Order Service did not start; see $log" -ForegroundColor Red
exit 1
