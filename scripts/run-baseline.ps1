# ============================================================
# Week 3 C0/C1 correctness captures (docs/baseline-c0-c1.md).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-baseline.ps1 `
#       -BaseUrl http://localhost:5080 -Container infra-postgres-1 `
#       -C0ConnectionString "Host=localhost;Port=5432;Database=flashsale;Username=order_service_user;Password=order_service_dev"
#
# Needs: Order Service running at -BaseUrl against the database inside
# -Container, with scripts/schema/baseline-schema.sql applied.
# Writes evidence to tests/baseline/results/ and exits 1 if any pass rule fails.
# ============================================================
param(
    [string]$BaseUrl = "http://localhost:5080",
    [string]$Container = "infra-postgres-1",
    [string]$C0ConnectionString = "Host=localhost;Port=5432;Database=flashsale;Username=order_service_user;Password=order_service_dev",
    [int]$C1Stock = 100,
    [int]$Repeats = 3,
    [string]$OutDir
)

# Continue: native-command stderr must not become a terminating error (PS 5.1).
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "tests\baseline\results" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$commit = (git -C $repoRoot rev-parse --short HEAD).Trim()
$dirty = [bool](git -C $repoRoot status --porcelain --untracked-files=no)
$summary = New-Object System.Collections.Generic.List[string]
$failures = 0

function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $sql" }
    return @($out | Where-Object { $_ -ne "" })
}

function Save-Result($name, $data) {
    $path = Join-Path $OutDir "$stamp-$name.json"
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
    return $path
}

# ---------------------------------------------------------------- C0 race
Write-Host "== C0 race (c0-demo-product, stock 1, 5 concurrent attempts)" -ForegroundColor Cyan
Sql "DELETE FROM order_service.baseline_orders WHERE product_id = 'c0-demo-product';" | Out-Null
$c0Log = Join-Path $OutDir "$stamp-c0-race.log"
$env:ConnectionStrings__Default = $C0ConnectionString
Push-Location (Join-Path $repoRoot "src\FlashSale.OrderService")
dotnet run --no-build --no-launch-profile -- --run-c0-demo *> $c0Log
$c0Exit = $LASTEXITCODE
Pop-Location
Remove-Item Env:\ConnectionStrings__Default
$c0Text = Get-Content $c0Log -Raw
$m = [regex]::Match($c0Text, "Result: (\d+) of (\d+) concurrent requests got 'Confirmed'")
$c0Confirmed = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
$c0Stock = [int]@(Sql "SELECT stock FROM order_service.inventory WHERE product_id = 'c0-demo-product';")[0]
$c0Rows = Sql "SELECT result || '=' || count(*) FROM order_service.baseline_orders WHERE product_id = 'c0-demo-product' AND config = 'C0' GROUP BY result ORDER BY result;"
$c0Pass = ($c0Exit -eq 0 -and $c0Confirmed -gt 1 -and $c0Stock -eq (1 - $c0Confirmed) -and $c0Stock -lt 0)
Save-Result "c0-race" ([ordered]@{
    commit = $commit; dirtyTree = $dirty; scenario = "C0 race"; initialStock = 1; attempts = 5
    confirmed = $c0Confirmed; finalStock = $c0Stock; baselineRows = $c0Rows
    verdict = $(if ($c0Pass) { "RACE CAPTURED" } else { "NOT CAPTURED" })
}) | Out-Null
$line = "C0 race: $c0Confirmed of 5 Confirmed for 1 unit, final stock $c0Stock -> " + $(if ($c0Pass) { "RACE CAPTURED" } else { "NOT CAPTURED" })
Write-Host $line -ForegroundColor $(if ($c0Pass) { "Green" } else { "Red" })
$summary.Add("- $line")
if (-not $c0Pass) { $failures++ }

# ---------------------------------------------------------------- C1 scenarios
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(60)
[System.Net.ServicePointManager]::DefaultConnectionLimit = 1000

$scenarios = @(
    @{ Name = "below"; Requests = [int]($C1Stock / 2) },
    @{ Name = "equal"; Requests = $C1Stock },
    @{ Name = "above"; Requests = [int]($C1Stock * 1.5) }
)
foreach ($s in $scenarios) {
    foreach ($run in 1..$Repeats) {
        $n = $s.Requests
        Sql "INSERT INTO order_service.inventory (product_id, stock) VALUES ('c1-demo-product', $C1Stock) ON CONFLICT (product_id) DO UPDATE SET stock = EXCLUDED.stock; DELETE FROM order_service.baseline_orders WHERE product_id = 'c1-demo-product';" | Out-Null

        # Start every request before reading any response.
        $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]]
        for ($i = 0; $i -lt $n; $i++) {
            $body = New-Object System.Net.Http.StringContent('{"productId":"c1-demo-product"}', [Text.Encoding]::UTF8, "application/json")
            $tasks.Add($client.PostAsync("$BaseUrl/api/c1/orders", $body))
        }
        try { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray()) } catch { }

        $status = @{}; $bodyConfirmed = 0; $bodyRejected = 0; $transportErrors = 0
        foreach ($t in $tasks) {
            if ($t.IsFaulted -or $t.IsCanceled) { $transportErrors++; continue }
            $code = [int]$t.Result.StatusCode
            $status["$code"] = 1 + $(if ($status.ContainsKey("$code")) { $status["$code"] } else { 0 })
            $text = $t.Result.Content.ReadAsStringAsync().Result
            if ($text -match '"result":"Confirmed"') { $bodyConfirmed++ } elseif ($text -match '"result":"Rejected"') { $bodyRejected++ }
        }
        $finalStock = [int]@(Sql "SELECT stock FROM order_service.inventory WHERE product_id = 'c1-demo-product';")[0]
        $dbConfirmed = [int]@(Sql "SELECT count(*) FROM order_service.baseline_orders WHERE product_id = 'c1-demo-product' AND config = 'C1' AND result = 'Confirmed';")[0]
        $dbRejected = [int]@(Sql "SELECT count(*) FROM order_service.baseline_orders WHERE product_id = 'c1-demo-product' AND config = 'C1' AND result = 'Rejected';")[0]

        $expConfirmed = [Math]::Min($n, $C1Stock)
        $expRejected = $n - $expConfirmed
        $checks = [ordered]@{
            allHttp200          = ($status.Keys.Count -eq 1 -and $status.ContainsKey("200") -and $status["200"] -eq $n -and $transportErrors -eq 0)
            confirmedExpected   = ($dbConfirmed -eq $expConfirmed -and $bodyConfirmed -eq $expConfirmed)
            rejectedExpected    = ($dbRejected -eq $expRejected -and $bodyRejected -eq $expRejected)
            noOversell          = ($dbConfirmed -le $C1Stock)
            stockNonNegative    = ($finalStock -ge 0)
            stockConserved      = ($finalStock -eq $C1Stock - $dbConfirmed)
            oneRowPerRequest    = ($dbConfirmed + $dbRejected -eq $n)
        }
        $pass = -not ($checks.Values -contains $false)
        $name = "c1-$($s.Name)-run$run"
        Save-Result $name ([ordered]@{
            commit = $commit; dirtyTree = $dirty; scenario = "C1 $($s.Name)"; run = $run
            initialStock = $C1Stock; concurrentRequests = $n; httpStatus = $status; transportErrors = $transportErrors
            confirmed = $dbConfirmed; rejected = $dbRejected; finalStock = $finalStock
            checks = $checks; verdict = $(if ($pass) { "PASS" } else { "FAIL" })
        }) | Out-Null
        $statusText = ($status.GetEnumerator() | Sort-Object Name | ForEach-Object { "HTTP $($_.Name) x$($_.Value)" }) -join ", "
        $line = "C1 $($s.Name) run $run`: $n requests, stock $C1Stock -> Confirmed $dbConfirmed, Rejected $dbRejected, final stock $finalStock, $statusText -> " + $(if ($pass) { "PASS" } else { "FAIL ($((($checks.GetEnumerator() | Where-Object { -not $_.Value }) | ForEach-Object { $_.Key }) -join ', '))" })
        Write-Host $line -ForegroundColor $(if ($pass) { "Green" } else { "Red" })
        $summary.Add("- $line")
        if (-not $pass) { $failures++ }
    }
}

$summaryPath = Join-Path $OutDir "$stamp-summary.md"
@("# C0/C1 baseline capture $stamp", "", "Commit: $commit$(if ($dirty) { ' (uncommitted changes present)' })", "Base URL: $BaseUrl; database container: $Container", "") + $summary | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "`nEvidence: $OutDir ($stamp-*)"
if ($failures -gt 0) { Write-Host "$failures scenario(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "All C0/C1 pass rules met." -ForegroundColor Green
