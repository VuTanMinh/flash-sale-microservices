# ============================================================
# Week 5 Order API checks (docs/order-api.md; test cases TP-A01..TP-A05).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-order-api.ps1 -BaseUrl http://localhost:5100 -Container verify-env-pg
#
# Needs Order Service running at -BaseUrl against the database in -Container.
# Run it with the broker unreachable (RabbitMQ__Connections__Default__Port set
# to an unused port) or a throwaway broker, so test orders are not published
# into a shared RabbitMQ. Exits 1 on any failure.
# ============================================================
param(
    [string]$BaseUrl = "http://localhost:5100",
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$ConcurrentRetries = 20
)
$ErrorActionPreference = "Continue"
$failures = 0
$api = "$BaseUrl/api/orders"
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
[System.Net.ServicePointManager]::DefaultConnectionLimit = 1000

function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Sql([string]$sql) {
    $out = $sql | docker exec -i $Container psql -U flashsale -d flashsale -At -v ON_ERROR_STOP=1 -f -
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $sql" }
    return (@($out | Where-Object { $_ -ne "" }) -join "`n")
}
function New-Post([string]$key, [string]$body) {
    $m = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $api)
    if ($null -ne $key) { $m.Headers.TryAddWithoutValidation("Idempotency-Key", $key) | Out-Null }
    $m.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, "application/json")
    return $m
}
function Post([string]$key, [string]$body) {
    $r = $client.SendAsync((New-Post $key $body)).Result
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $r.Content.ReadAsStringAsync().Result }
}
function Rows([string]$key) {
    $k = $key.Replace("'", "''")
    return [int](Sql "SELECT count(*) FROM order_service.orders WHERE `"IdempotencyKey`" = '$k';")
}
function OutboxRows([string]$key) {
    $k = $key.Replace("'", "''")
    return [int](Sql "SELECT count(*) FROM order_service.outbox_events e JOIN order_service.orders o ON o.`"Id`" = e.`"OrderId`" WHERE o.`"IdempotencyKey`" = '$k' AND e.`"EventType`" = 'OrderPlaced';")
}
$ok = '{"productId":"flash-product-1","quantity":1}'

# TP-A01 accepted intake and polling
$k = [guid]::NewGuid().ToString()
$r1 = Post $k $ok
$o1 = $r1.Body | ConvertFrom-Json
Check "TP-A01 new order -> 201 PendingStock" ($r1.Status -eq 201 -and $o1.state -eq "PendingStock" -and $o1.quantity -eq 1) "$($r1.Status) $($r1.Body)"
Check "TP-A01 one order row and one OrderPlaced Outbox row" ((Rows $k) -eq 1 -and (OutboxRows $k) -eq 1)
Check "TP-A01 timestamps are UTC (Z suffix)" ($r1.Body -match '"requestAcceptedAt":"[^"]+Z"')
$g = $client.GetAsync("$api/$($o1.id)").Result
$gBody = $g.Content.ReadAsStringAsync().Result
Check "TP-A01 poll -> 200 with the same order" ([int]$g.StatusCode -eq 200 -and ($gBody | ConvertFrom-Json).id -eq $o1.id) "$([int]$g.StatusCode)"
$u = $client.GetAsync("$api/$([guid]::NewGuid())").Result
Check "TP-A01 poll unknown id -> 404" ([int]$u.StatusCode -eq 404)

# TP-A02 request validation and quantity = 1
$cases = [ordered]@{
    "missing Idempotency-Key"   = @($null, $ok)
    "blank Idempotency-Key"     = @("   ", $ok)
    "quantity 0"                = @("new", '{"productId":"flash-product-1","quantity":0}')
    "quantity 2"                = @("new", '{"productId":"flash-product-1","quantity":2}')
    "quantity -1"               = @("new", '{"productId":"flash-product-1","quantity":-1}')
    "quantity missing"          = @("new", '{"productId":"flash-product-1"}')
    "productId missing"         = @("new", '{"quantity":1}')
    "productId empty"           = @("new", '{"productId":"","quantity":1}')
    "productId whitespace"      = @("new", '{"productId":"   ","quantity":1}')
    "malformed JSON"            = @("new", '{not json')
}
foreach ($name in $cases.Keys) {
    $key = $cases[$name][0]
    if ($key -eq "new") { $key = [guid]::NewGuid().ToString() }
    $r = Post $key $cases[$name][1]
    $rows = if ($key -and $key.Trim()) { Rows $key } else { 0 }
    Check "TP-A02 $name -> 400, nothing stored" ($r.Status -eq 400 -and $rows -eq 0) "$($r.Status), rows $rows"
}

# TP-A03 unchanged-payload replay
$r2 = Post $k $ok
Check "TP-A03 replay -> 200 with the original order" ($r2.Status -eq 200 -and ($r2.Body | ConvertFrom-Json).id -eq $o1.id) "$($r2.Status)"
Check "TP-A03 replay body equals the original body" ($r2.Body -ceq $r1.Body) "first: $($r1.Body) | replay: $($r2.Body)"
Check "TP-A03 still one order and one Outbox row" ((Rows $k) -eq 1 -and (OutboxRows $k) -eq 1)

# TP-A04 changed-payload conflict
$before = Sql "SELECT `"ProductId`" || '|' || `"Quantity`" FROM order_service.orders WHERE `"IdempotencyKey`" = '$k';"
$r3 = Post $k '{"productId":"flash-product-2","quantity":1}'
Check "TP-A04 same key, different product -> 409" ($r3.Status -eq 409) "$($r3.Status)"
$after = Sql "SELECT `"ProductId`" || '|' || `"Quantity`" FROM order_service.orders WHERE `"IdempotencyKey`" = '$k';"
Check "TP-A04 original order unchanged, still one row" ($before -eq $after -and (Rows $k) -eq 1)

# TP-A05 concurrent retries of one key
foreach ($round in 1..3) {
    $ck = [guid]::NewGuid().ToString()
    $tasks = @(1..$ConcurrentRetries | ForEach-Object { $client.SendAsync((New-Post $ck $ok)) })
    try { [System.Threading.Tasks.Task]::WaitAll($tasks) } catch { }
    $codes = @($tasks | ForEach-Object { if ($_.IsFaulted) { "error" } else { [int]$_.Result.StatusCode } })
    $ids = @($tasks | Where-Object { -not $_.IsFaulted } | ForEach-Object { ($_.Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json).id } | Select-Object -Unique)
    $summary = ($codes | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ", "
    Check "TP-A05 round $round`: $ConcurrentRetries concurrent same-key requests -> one 201, rest 200, no 5xx ($summary)" (@($codes | Where-Object { $_ -eq 201 }).Count -eq 1 -and @($codes | Where-Object { $_ -eq 200 }).Count -eq ($ConcurrentRetries - 1))
    Check "TP-A05 round $round`: every response names the same order; one order and one Outbox row" ($ids.Count -eq 1 -and (Rows $ck) -eq 1 -and (OutboxRows $ck) -eq 1) "ids $($ids.Count), rows $(Rows $ck), outbox $(OutboxRows $ck)"
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Order API behaves as specified in docs/order-api.md." -ForegroundColor Green
