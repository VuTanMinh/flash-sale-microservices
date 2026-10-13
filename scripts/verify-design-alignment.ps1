# ============================================================
# Week 4 design alignment checks (docs/design-alignment.md).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-design-alignment.ps1 [-BaseUrl http://localhost:5100]
#
# Static checks against the source; with -BaseUrl it also compares
# docs/api-contract-v1.json with the live /swagger/v1/swagger.json of a
# running Order Service built from the same commit. Exits 1 on any mismatch.
# The ERD is checked separately against a live DB by verify-erd.ps1.
# ============================================================
param([string]$BaseUrl)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { Write-Host "FAIL  $name $(if ($detail) { "-- $detail" })" -ForegroundColor Red; $script:failures++ }
}
function Read([string]$rel) { Get-Content (Join-Path $root $rel) -Raw -Encoding UTF8 }

# Public auto-properties of a C# class: "Name:Type" (type normalised: bool/int/string/Guid/DateTime[?]).
function Get-CsProperties([string]$rel) {
    $text = Read $rel
    $props = [regex]::Matches($text, 'public\s+([A-Za-z?<>]+)\s+([A-Za-z]+)\s*\{\s*get;') | ForEach-Object { "$($_.Groups[2].Value):$($_.Groups[1].Value)" }
    return @($props | Sort-Object)
}

# ---------------------------------------------------------------- class diagram
$cd = Read "docs\class-diagram.md"
$classMap = [ordered]@{
    "Order"                     = "src\FlashSale.OrderService\Entities\Order.cs"
    "OrderStatusHistory"        = "src\FlashSale.OrderService\Entities\OrderStatusHistory.cs"
    "OutboxEvent"               = "src\FlashSale.OrderService\Entities\OutboxEvent.cs"
    "ProcessedMessage"          = "src\FlashSale.OrderService\Entities\ProcessedMessage.cs"
    "InventoryOutboxEvent"      = "src\FlashSale.InventoryService\Entities\OutboxEvent.cs"
    "InventoryProcessedMessage" = "src\FlashSale.InventoryService\Entities\ProcessedMessage.cs"
    "OrderPlacedEto"            = "src\FlashSale.EventContracts\OrderPlacedEto.cs"
    "StockReservedEto"          = "src\FlashSale.EventContracts\StockReservedEto.cs"
    "StockRejectedEto"          = "src\FlashSale.EventContracts\StockRejectedEto.cs"
    "OrderProcessingStartedEto" = "src\FlashSale.EventContracts\OrderProcessingStartedEto.cs"
    "OrderProcessedEto"         = "src\FlashSale.EventContracts\OrderProcessedEto.cs"
}
foreach ($cls in $classMap.Keys) {
    $m = [regex]::Match($cd, "class $cls(\[[^\]]*\])? \{([^}]*)\}")
    if (-not $m.Success) { Check "class diagram has $cls" $false; continue }
    $drawn = @([regex]::Matches($m.Groups[2].Value, '\+([A-Za-z?<>]+) ([A-Za-z]+)\s*$', 'Multiline') | ForEach-Object { "$($_.Groups[2].Value):$($_.Groups[1].Value)" } | Sort-Object)
    $code = Get-CsProperties $classMap[$cls]
    Check "class diagram $cls properties = code ($($code.Count))" (($drawn -join ",") -eq ($code -join ",")) "diagram: $($drawn -join ', ') | code: $($code -join ', ')"
}
$enumCode = [regex]::Match((Read "src\FlashSale.OrderService\Entities\OrderState.cs"), 'enum OrderState\s*\{([^}]*)\}').Groups[1].Value -split '[,\s]+' | Where-Object { $_ } | Sort-Object
$enumDrawn = [regex]::Match($cd, 'class OrderState \{\s*<<enumeration>>([^}]*)\}').Groups[1].Value -split '\s+' | Where-Object { $_ } | Sort-Object
Check "class diagram OrderState values = code enum" (($enumCode -join ",") -eq ($enumDrawn -join ",")) "code: $($enumCode -join ',') drawn: $($enumDrawn -join ',')"
Check "class diagram draws the six-state additions as implemented (not planned)" (-not ($cd -match "## Planned \(Week 11, not in code yet\)") -and $cd -match "OrderProcessingStartedEto" -and $cd -match "OrderStatusHistory")

# ---------------------------------------------------------------- event contract
$ec = Read "docs\event-contract.md"
foreach ($eto in "OrderPlacedEto", "StockReservedEto", "StockRejectedEto", "OrderProcessingStartedEto", "OrderProcessedEto") {
    $sec = [regex]::Match($ec, "## ``$eto``(.*?)(?=\n## )", 'Singleline').Groups[1].Value
    $rows = @([regex]::Matches($sec, '^\|\s*`([A-Za-z]+)`\s*\|\s*`([A-Za-z?]+)`', 'Multiline') | ForEach-Object { "$($_.Groups[1].Value):$($_.Groups[2].Value)" } | Sort-Object)
    $code = Get-CsProperties $classMap[$eto]
    Check "event contract $eto fields = code" (($rows -join ",") -eq ($code -join ",")) "doc: $($rows -join ', ') | code: $($code -join ', ')"
}
Check "event contract documents OrderProcessingStartedEto as implemented (derivation recorded)" ($ec -match '## `OrderProcessingStartedEto`' -and $ec -match 'DeriveMessageId' -and $ec -match '9e1b5c2a-3d4f-4a6b-8c7d-0e9f1a2b3c4d')
# Routing keys appear as string literals in the messaging code, either as
# routingKey: "X" or as a positional argument to the queue bind/publish helpers.
$routingCode = (Get-ChildItem (Join-Path $root "src") -Recurse -Filter *.cs | Where-Object { $_.FullName -like "*\Messaging\*" -or $_.Name -like "*Processor.cs" } | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
foreach ($key in "OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed") {
    Check "routing key '$key' in event contract is used in code" ($ec -match "\| ``$key`` \|" -and $routingCode -match "`"$key`"")
}
Check "exchange name in event contract matches configuration" ($ec -match 'flashsale\.order\.exchange' -and (Read "src\FlashSale.OrderService\appsettings.json") -match '"ExchangeName": "flashsale.order.exchange"')

# ---------------------------------------------------------------- state model
$sm = Read "docs\order-state-machine.md"
foreach ($s in "PendingStock", "Confirmed", "Rejected", "Processing", "Completed", "ProcessingFailed") {
    Check "state model names teacher state $s" ($sm -match "``$s``")
}
$orderCs = Read "src\FlashSale.OrderService\Entities\Order.cs"
$codeTransitions = @([regex]::Matches($orderCs, '\[OrderState\.(\w+)\]\s*=\s*\[([^\]]*)\]') | ForEach-Object {
    $from = $_.Groups[1].Value
    [regex]::Matches($_.Groups[2].Value, 'OrderState\.(\w+)') | ForEach-Object { "$from>$($_.Groups[1].Value)" } })
foreach ($t in $codeTransitions) {
    $f, $to = $t.Split('>')
    Check "state doc lists current-code transition $f -> $to" ($sm -match "\| ``$f`` → ``$to`` \|")
}
Check "state doc says the six-state model is implemented (Week 11 box 2 / TP-P02)" ($sm -match 'TP-P02' -and $sm -match '`ProcessingFailed`')

# ---------------------------------------------------------------- sequence diagrams
$sq = Read "docs\sequence-diagrams.md"
$ctrl = Read "src\FlashSale.OrderService\Controllers\OrdersController.cs"
Check "sequence diagram POST returns 201 like the controller" ($sq -match "201 Created" -and $ctrl -match "StatusCode\(201")
$poll = [regex]::Match((Read "src\FlashSale.OrderService\Messaging\OutboxPublisherWorker.cs"), 'PollInterval = TimeSpan\.FromSeconds\((\d+)\)').Groups[1].Value
Check "sequence diagram Outbox poll interval matches code (${poll}s)" ($sq -match "every ${poll}s")
foreach ($key in [regex]::Matches($sq, 'routing key "(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) {
    Check "sequence diagram routing key '$key' exists in code" ($routingCode -match "`"$key`"")
}
Check "sequence diagrams draw the Processing hop as real (no PLANNED note)" (($sq -notmatch "PLANNED \(Week 11\), not in code yet") -and $sq -match 'publish OrderProcessingStartedEto')
foreach ($stale in "turned out not to exist", "never passes through a ``Processing``", "removed from the domain") {
    Check "no stale claim '$stale' in design docs" (-not (($sq + $ec + $cd + $sm) -match [regex]::Escape($stale)))
}

# ---------------------------------------------------------------- API contract
$api = (Read "docs\api-contract-v1.json") | ConvertFrom-Json
function Get-ApiCodes($path, $method) { @($api.paths.$path.$method.responses.PSObject.Properties.Name | Sort-Object) }
function Get-SourceCodes([string]$src, [string]$methodRegex) {
    $m = [regex]::Match($src, "((?:\s*\[ProducesResponseType[^\]]*\]\s*)+)\s*public[^\n]*$methodRegex")
    $map = @{ "Status200OK" = "200"; "Status201Created" = "201"; "Status400BadRequest" = "400"; "Status404NotFound" = "404"; "Status409Conflict" = "409" }
    @([regex]::Matches($m.Groups[1].Value, 'StatusCodes\.(\w+)') | ForEach-Object { $map[$_.Groups[1].Value] } | Sort-Object)
}
$baseCtrl = Read "src\FlashSale.OrderService\Controllers\BaselineOrdersController.cs"
foreach ($e in @(
    @{ P = "/api/orders"; M = "post"; Src = $ctrl; Rx = "CreateOrderAsync" },
    @{ P = "/api/orders/{id}"; M = "get"; Src = $ctrl; Rx = "GetOrderAsync" },
    @{ P = "/api/c1/orders"; M = "post"; Src = $baseCtrl; Rx = "PlaceOrderAsync" })) {
    $doc = Get-ApiCodes $e.P $e.M
    $src = Get-SourceCodes $e.Src $e.Rx
    Check "API contract $($e.M.ToUpper()) $($e.P) codes = controller ($($src -join ','))" ($src.Count -gt 0 -and ($doc -join ",") -eq ($src -join ",")) "contract: $($doc -join ',')"
}
$hdr = @($api.paths.'/api/orders'.post.parameters | Where-Object { $_.name -eq "Idempotency-Key" })
Check "API contract documents the Idempotency-Key header" ($hdr.Count -eq 1)
if ($BaseUrl) {
    $live = (Invoke-WebRequest -UseBasicParsing "$BaseUrl/swagger/v1/swagger.json").Content | ConvertFrom-Json | ConvertTo-Json -Depth 50 -Compress
    $file = $api | ConvertTo-Json -Depth 50 -Compress
    Check "docs/api-contract-v1.json equals the live export at $BaseUrl" ($live -eq $file)
}

# ---------------------------------------------------------------- tracked in git
$ErrorActionPreference = "Continue"   # git ls-files reports untracked files on stderr
foreach ($f in "docs/erd.md", "docs/class-diagram.md", "docs/api-contract-v1.json", "docs/event-contract.md", "docs/order-state-machine.md", "docs/sequence-diagrams.md", "docs/design-alignment.md") {
    $tracked = git -C $root ls-files --error-unmatch $f 2>$null
    Check "$f is committed" ([bool]$tracked)
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "All design artifacts align with the source (planned parts labelled)." -ForegroundColor Green
