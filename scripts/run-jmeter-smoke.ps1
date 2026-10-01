# ============================================================
# C1 JMeter smoke run with saved, checked evidence (Week 3).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-jmeter-smoke.ps1 `
#       -JMeter D:\tools\apache-jmeter-5.6.3\bin\jmeter.bat -Container verify-env-pg -Port 5100
#
# Needs Order Service running at http://localhost:<Port> against the database
# in -Container. Steps: reset+seed -> run tests/jmeter/smoke-test.jmx (10
# threads x 1 POST /api/c1/orders, status + content assertions) -> save the
# JTL -> check the JTL and the database agree. Exits 1 on any mismatch.
# -Product lets you aim at an unstocked product to prove the assertions fail.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$JMeter,
    [string]$Container,
    [int]$Port = 5100,
    [string]$Product = "flash-product-1",
    [int]$ExpectedSamples = 10,
    [int]$SeedStock = 1000
)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$composeFile = Join-Path $repoRoot "infra\docker-compose.yml"
$resultsDir = Join-Path $repoRoot "tests\jmeter\results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$jtl = Join-Path $resultsDir "$stamp-c1-smoke.jtl"
$summaryPath = Join-Path $resultsDir "$stamp-c1-smoke-summary.md"
$failures = 0
$lines = New-Object System.Collections.Generic.List[string]

function Psql([string]$sql) {
    if ($Container) { $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - }
    else { $out = $sql | docker compose -f $composeFile exec -T postgres psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f - }
    return @($out | Where-Object { $_ -ne "" })
}
function Check([string]$name, [bool]$ok, [string]$detail) {
    $line = $(if ($ok) { "PASS" } else { "FAIL" }) + "  $name" + $(if ($detail) { " ($detail)" })
    Write-Host $line -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
    $lines.Add("- $line")
    if (-not $ok) { $script:failures++ }
}

# 1. Known starting state
$rs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $repoRoot "scripts\reset-and-seed.ps1"))
if ($Container) { $rs += @("-Container", $Container) }
powershell @rs *> $null
Check "reset-and-seed" ($LASTEXITCODE -eq 0) ""
$startStock = @(Psql "SELECT stock FROM order_service.inventory WHERE product_id = 'flash-product-1';")[0]
Check "flash-product-1 starts at $SeedStock" ("$startStock" -eq "$SeedStock") "actual $startStock"

# 2. Run the checked-in plan
& $JMeter -n -t (Join-Path $repoRoot "tests\jmeter\smoke-test.jmx") -l $jtl -j (Join-Path $env:TEMP "$stamp-jmeter.log") `
    "-Jport=$Port" "-Jproduct=$Product" "-Jjmeter.save.saveservice.assertion_results_failure_message=true" *> $null
Check "JMeter exited 0" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

# 3. The JTL must match the plan and the intended endpoint
$rows = @(Import-Csv $jtl)
Check "JTL has $ExpectedSamples samples" ($rows.Count -eq $ExpectedSamples) "actual $($rows.Count)"
$wrongUrl = @($rows | Where-Object { $_.URL -ne "http://localhost:$Port/api/c1/orders" })
Check "every sample hit POST /api/c1/orders on port $Port" ($wrongUrl.Count -eq 0) "$($wrongUrl.Count) other URL(s)"
$non200 = @($rows | Where-Object { $_.responseCode -ne "200" })
Check "every sample returned HTTP 200" ($non200.Count -eq 0) "$($non200.Count) not 200"
$failedAssert = @($rows | Where-Object { $_.success -ne "true" })
Check "every sample passed the status and content assertions" ($failedAssert.Count -eq 0) $(if ($failedAssert.Count) { "$($failedAssert.Count) failed: $($failedAssert[0].failureMessage)" })

# 4. The database must agree with the JTL
$confirmed = @(Psql "SELECT count(*) FROM order_service.baseline_orders WHERE config = 'C1' AND product_id = '$Product' AND result = 'Confirmed';")[0]
$allRows = @(Psql "SELECT count(*) FROM order_service.baseline_orders;")[0]
$endStock = @(Psql "SELECT stock FROM order_service.inventory WHERE product_id = 'flash-product-1';")[0]
Check "database logged $ExpectedSamples Confirmed C1 decisions and nothing else" ("$confirmed" -eq "$ExpectedSamples" -and "$allRows" -eq "$ExpectedSamples") "Confirmed $confirmed, total rows $allRows"
Check "flash-product-1 stock fell by exactly $ExpectedSamples" ("$endStock" -eq "$($SeedStock - $ExpectedSamples)") "actual $endStock"

$commit = (git -C $repoRoot rev-parse --short HEAD).Trim()
$dirty = [bool](git -C $repoRoot status --porcelain --untracked-files=no)
@("# C1 JMeter smoke run $stamp", "",
  "Commit: $commit$(if ($dirty) { ' (uncommitted changes present)' }); plan: tests/jmeter/smoke-test.jmx; product: $Product; port: $Port",
  "Raw result: $([IO.Path]::GetFileName($jtl))", "") + $lines | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "`nEvidence: $jtl"
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Smoke run passed: JTL and database agree." -ForegroundColor Green
