# ============================================================
# Builds a throwaway PostgreSQL and proves the database setup end to end.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-environment.ps1 -Mode Fresh
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-environment.ps1 -Mode Existing
#
# Fresh    -- new volume: infra/initdb runs automatically, then both services'
#             migrations as their own accounts, then the baseline schema.
# Existing -- copy of the running local database (pg_dump from -SourceContainer,
#             read-only), role script applied twice (idempotence), migrations,
#             baseline schema.
# Both end with scripts/verify-erd.ps1 plus account-isolation checks. The
# running database is never written to; the temporary container is removed
# unless -Keep is given. Exits 1 on any failure.
# ============================================================
param(
    [ValidateSet("Fresh", "Existing")][string]$Mode = "Fresh",
    [string]$SourceContainer = "infra-postgres-1",
    [int]$Port = 55432,
    [switch]$SkipBuild,
    [switch]$Keep
)

# Continue, not Stop: in Windows PowerShell 5.1, redirected stderr from a
# native command (docker, psql, dotnet) becomes a terminating error under
# Stop. Every native call checks $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$container = "verify-env-pg"
$initdb = Join-Path $repoRoot "infra\initdb"
$roleScript = Join-Path $initdb "01-create-service-roles.sql"
$script:failures = 0

function Step([string]$text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Pass([string]$text) { Write-Host "PASS  $text" -ForegroundColor Green }
function Fail([string]$text) { Write-Host "FAIL  $text" -ForegroundColor Red; $script:failures++ }

function Invoke-Psql([string]$user, [string]$password, [string]$sql) {
    # SQL on stdin: Windows PowerShell 5.1 strips embedded double quotes from
    # native-command arguments.
    $out = $sql | docker exec -i -e "PGPASSWORD=$password" $container psql -h localhost -U $user -d flashsale -At -v ON_ERROR_STOP=1 -f - 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out | Out-String).Trim() }
}

function Invoke-Migration([string]$project, [string]$connectionString) {
    $env:ConnectionStrings__Default = $connectionString
    $log = Join-Path $env:TEMP "$project-migrate.log"
    Push-Location (Join-Path $repoRoot "src")
    try {
        # Output goes to a file, never through a truncating pipe: closing the
        # pipe early kills the process and reports a false failure.
        dotnet run --project $project --no-build --migrate-database *> $log
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        Remove-Item Env:\ConnectionStrings__Default -ErrorAction SilentlyContinue
    }
    $text = Get-Content $log -Raw
    if ($code -eq 0 -and $text -match "Successfully completed all database migrations") {
        Pass "$project migrations (as its own account)"
    } else {
        Fail "$project migrations exit=$code; see $log"
        Get-Content $log -Tail 15 | Write-Host
    }
}

try {
    Step "SDK and build"
    $globalJson = Get-Content (Join-Path $repoRoot "global.json") -Raw | ConvertFrom-Json
    $sdk = (dotnet --version).Trim()
    $want = $globalJson.sdk.version
    # rollForward=latestPatch: same major.minor.feature band (10.0.3xx), patch >= pinned.
    $band = $want.Substring(0, $want.Length - 2)
    if ($sdk.StartsWith($band) -and [int]$sdk.Substring($band.Length) -ge [int]$want.Substring($band.Length)) {
        Pass ".NET SDK $sdk matches global.json $want (latestPatch)"
    } else {
        Fail ".NET SDK $sdk does not match global.json $want"
    }
    powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\create-openiddict-cert.ps1") | Out-Null
    if ($LASTEXITCODE -eq 0) { Pass "Order Service signing certificate (openiddict.pfx) present" } else { Fail "could not create openiddict.pfx" }
    if (-not $SkipBuild) {
        $buildLog = Join-Path $env:TEMP "verify-env-build.log"
        dotnet build (Join-Path $repoRoot "src\FlashSale.OrderService.slnx") --no-incremental -nologo *> $buildLog
        $buildText = Get-Content $buildLog -Raw
        if ($LASTEXITCODE -eq 0 -and $buildText -match "0 Error\(s\)") {
            $warn = [regex]::Match($buildText, "(\d+) Warning\(s\)").Groups[1].Value
            Pass "clean build of the solution (0 errors, $warn warnings)"
        } else {
            Fail "build failed; see $buildLog"
            throw "Cannot continue without a successful build."
        }
    }

    Step "Throwaway PostgreSQL ($Mode) on port $Port"
    docker rm -f $container *> $null
    if ($Mode -eq "Fresh") {
        docker run -d --name $container -e POSTGRES_USER=flashsale -e POSTGRES_PASSWORD=flashsale_dev -e POSTGRES_DB=flashsale `
            -p "${Port}:5432" -v "${initdb}:/docker-entrypoint-initdb.d:ro" postgres:16 | Out-Null
    } else {
        docker run -d --name $container -e POSTGRES_USER=flashsale -e POSTGRES_PASSWORD=flashsale_dev -e POSTGRES_DB=flashsale `
            -p "${Port}:5432" postgres:16 | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "Could not start the temporary PostgreSQL container." }
    # The image restarts once after running init scripts; wait for a real TCP connection.
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 1
        docker exec $container psql -h localhost -U flashsale -d flashsale -Atc "SELECT 1" *> $null
        $ready = ($LASTEXITCODE -eq 0)
    }
    if (-not $ready) { throw "Temporary PostgreSQL did not become ready." }
    Start-Sleep -Seconds 2
    Pass "temporary database is up"

    if ($Mode -eq "Existing") {
        Step "Copy the existing database (read-only dump of $SourceContainer)"
        docker exec $SourceContainer pg_dump -U flashsale -d flashsale | docker exec -i $container psql -q -U flashsale -d flashsale -v ON_ERROR_STOP=1 *> $null
        if ($LASTEXITCODE -ne 0) { throw "Could not copy $SourceContainer." }
        Pass "copied $SourceContainer"
        foreach ($run in 1, 2) {
            Get-Content -Raw $roleScript | docker exec -i $container psql -q -U flashsale -d flashsale -v ON_ERROR_STOP=1 *> $null
            if ($LASTEXITCODE -eq 0) { Pass "role script applied (run $run of 2, idempotent)" } else { Fail "role script failed on run $run" }
        }
    } else {
        $schemas = (Invoke-Psql "flashsale" "flashsale_dev" "SELECT string_agg(nspname || '=' || pg_get_userbyid(nspowner), ',' ORDER BY nspname) FROM pg_namespace WHERE nspname IN ('order_service','inventory_service')").Output
        if ($schemas -eq "inventory_service=inventory_service_user,order_service=order_service_user") { Pass "initdb created schemas with service owners" } else { Fail "initdb schemas: $schemas" }
    }

    Step "Migrations with the dedicated accounts"
    Invoke-Migration "FlashSale.OrderService" "Host=localhost;Port=$Port;Database=flashsale;Username=order_service_user;Password=order_service_dev"
    Invoke-Migration "FlashSale.InventoryService" "Host=localhost;Port=$Port;Database=flashsale;Username=inventory_service_user;Password=inventory_service_dev;Search Path=inventory_service"

    Step "Baseline (C0/C1) schema"
    Get-Content -Raw (Join-Path $repoRoot "scripts\schema\baseline-schema.sql") | docker exec -i $container psql -q -U flashsale -d flashsale -v ON_ERROR_STOP=1 *> $null
    if ($LASTEXITCODE -eq 0) { Pass "baseline schema applied" } else { Fail "baseline schema failed" }

    Step "Order Service starts against this database (own account)"
    $svcLog = Join-Path $env:TEMP "verify-env-order-service.log"
    $env:ConnectionStrings__Default = "Host=localhost;Port=$Port;Database=flashsale;Username=order_service_user;Password=order_service_dev;Maximum Pool Size=60"
    $env:ASPNETCORE_URLS = "http://localhost:5181"
    $svc = Start-Process -FilePath dotnet -ArgumentList "run", "--no-build", "--no-launch-profile" `
        -WorkingDirectory (Join-Path $repoRoot "src\FlashSale.OrderService") `
        -RedirectStandardOutput $svcLog -RedirectStandardError "$svcLog.err" -WindowStyle Hidden -PassThru
    $env:ConnectionStrings__Default = $null
    $env:ASPNETCORE_URLS = $null
    # A real API call, not just "any HTTP answer": a C1 order for a product
    # with no stock row must come back 200 with result Rejected. (A 500 for
    # every request -- e.g. ABP's missing-libs page -- must fail this check.)
    $answered = $false; $lastStatus = "no response"
    for ($i = 0; $i -lt 60 -and -not $answered -and -not $svc.HasExited; $i++) {
        Start-Sleep -Seconds 2
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType "application/json" `
                -Body '{"productId":"verify-environment-probe"}' "http://localhost:5181/api/c1/orders" -TimeoutSec 5 -ErrorAction Stop
            $answered = ($r.StatusCode -eq 200 -and $r.Content -match '"result":"Rejected"')
            $lastStatus = "HTTP $($r.StatusCode) $($r.Content)"
        }
        catch { if ($_.Exception.Response) { $lastStatus = "HTTP $([int]$_.Exception.Response.StatusCode)"; if ([int]$_.Exception.Response.StatusCode -ge 500) { break } } }
    }
    # Stop only the process tree this script started (dotnet run -> service
    # exe), never an Order Service the user is running.
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.Id)" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $svc.HasExited) { Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue }
    if ($answered) { Pass "Order Service started; POST /api/c1/orders returned 200 Rejected for an unstocked product" }
    else {
        Fail "Order Service API check failed ($lastStatus); see $svcLog"
        Select-String -Path $svcLog -Pattern "FTL|Exception" | Select-Object -First 3 | ForEach-Object { Write-Host "      $($_.Line)" }
    }

    Step "Account isolation"
    $checks = @(
        @{ U = "order_service_user"; P = "order_service_dev"; Sql = "SELECT count(*) FROM order_service.orders"; Allowed = $true },
        @{ U = "order_service_user"; P = "order_service_dev"; Sql = "UPDATE order_service.inventory SET stock = stock WHERE false"; Allowed = $true },
        @{ U = "order_service_user"; P = "order_service_dev"; Sql = "SELECT count(*) FROM public.""AbpUsers"""; Allowed = $true },
        @{ U = "order_service_user"; P = "order_service_dev"; Sql = "SELECT count(*) FROM inventory_service.outbox_events"; Allowed = $false },
        @{ U = "inventory_service_user"; P = "inventory_service_dev"; Sql = "SELECT count(*) FROM inventory_service.outbox_events"; Allowed = $true },
        @{ U = "inventory_service_user"; P = "inventory_service_dev"; Sql = "SELECT count(*) FROM order_service.orders"; Allowed = $false },
        @{ U = "inventory_service_user"; P = "inventory_service_dev"; Sql = "SELECT count(*) FROM public.""AbpUsers"""; Allowed = $false }
    )
    foreach ($c in $checks) {
        $r = Invoke-Psql $c.U $c.P $c.Sql
        $label = "$($c.U): $($c.Sql) -> " + $(if ($c.Allowed) { "allowed" } else { "denied" })
        if ($r.Ok -eq $c.Allowed -and ($c.Allowed -or $r.Output -match "permission denied")) { Pass $label } else { Fail "$label (got: $($r.Output))" }
    }

    Step "Schema matches docs/erd.md"
    powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\verify-erd.ps1") -Container $container
    if ($LASTEXITCODE -eq 0) { Pass "verify-erd.ps1" } else { Fail "verify-erd.ps1" }
}
catch {
    Fail $_.Exception.Message
}
finally {
    if (-not $Keep) { docker rm -f $container *> $null }
}

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) failed ($Mode)." -ForegroundColor Red
    exit 1
}
Write-Host "All checks passed ($Mode)." -ForegroundColor Green
