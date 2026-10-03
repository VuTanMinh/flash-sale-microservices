# ============================================================
# Checks docs/design-decisions.md against the code (Week 4).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-design-decisions.ps1
#
# 1. Every mechanism the doc cites exists in the named file.
# 2. The four required topics are defined.
# 3. Each check below asserts the state of the code as it should be today, so
#    it fails on purpose when a gap is fixed (or reintroduced) and this doc is
#    not updated in the same change.
# Exits 1 on any mismatch.
# ============================================================
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
function Src([string]$rel) { Get-Content (Join-Path $root $rel) -Raw -Encoding UTF8 }
$doc = Src "docs\design-decisions.md"

# 1. Cited mechanisms: doc mention -> file -> pattern that must exist there
$citations = @(
    @("OrdersController.CreateOrderAsync", "src\FlashSale.OrderService\Controllers\OrdersController.cs", 'CreateOrderAsync'),
    @("409 on reused key", "src\FlashSale.OrderService\Controllers\OrdersController.cs", 'return Conflict\('),
    @("unique IdempotencyKey", "src\FlashSale.OrderService\Data\OrderServiceDbContext.cs", 'HasIndex\(x => x\.IdempotencyKey\)\.IsUnique\(\)'),
    @("Order Inbox unique MessageId", "src\FlashSale.OrderService\Data\OrderServiceDbContext.cs", 'HasIndex\(x => x\.MessageId\)\.IsUnique\(\)'),
    @("Inventory Inbox unique MessageId", "src\FlashSale.InventoryService\Data\InventoryServiceDbContext.cs", 'HasIndex\(x => x\.MessageId\)\.IsUnique\(\)'),
    @("Inventory Outbox unique OrderId", "src\FlashSale.InventoryService\Data\InventoryServiceDbContext.cs", 'HasIndex\(x => x\.OrderId\)\.IsUnique\(\)'),
    @("StockResultProcessor.ProcessAsync", "src\FlashSale.OrderService\Messaging\StockResultProcessor.cs", 'ProcessAsync\('),
    @("StockResultProcessor same-or-past-state no-op", "src\FlashSale.OrderService\Messaging\StockResultProcessor.cs", 'IsAtOrPast\(order\.State, targetState\)'),
    @("AlreadyProcessed outcome", "src\FlashSale.OrderService\Messaging\StockResultProcessor.cs", 'ResultProcessingOutcome\.AlreadyProcessed'),
    @("OrderPlacedProcessor Inbox check first", "src\FlashSale.InventoryService\Messaging\OrderPlacedProcessor.cs", 'ProcessedMessages\.AnyAsync'),
    @("OrderPlacedProcessor DUPLICATE treated as StockReserved", "src\FlashSale.InventoryService\Messaging\OrderPlacedProcessor.cs", 'ReservationResult\.Duplicate => "StockReserved"'),
    @("one SaveChangesAsync for Outbox + Inbox", "src\FlashSale.InventoryService\Messaging\OrderPlacedProcessor.cs", 'ProcessedMessages\.Add[\s\S]*SaveChangesAsync'),
    @("reserve.lua DUPLICATE via processed set", "scripts\redis\reserve.lua", "SISMEMBER[\s\S]*'DUPLICATE'"),
    @("reserve.lua atomic DECR + SADD", "scripts\redis\reserve.lua", "DECR[\s\S]*SADD"),
    @("Order.TransitionTo guard", "src\FlashSale.OrderService\Entities\Order.cs", 'throw new InvalidOrderStateTransitionException'),
    @("Process Worker MessageId = OrderId", "src\FlashSale.ProcessWorker\Messaging\StockReservedConsumer.cs", 'MessageId = stockReserved\.OrderId'),
    @("reconciliation re-publishes OrderPlaced (new MessageId)", "src\FlashSale.OrderService\Messaging\ReconciliationWorker.cs", 'OutboxEvent\.ForOrderPlaced'),
    @("grants revoke cross-schema access", "infra\initdb\01-create-service-roles.sql", 'REVOKE ALL ON SCHEMA inventory_service FROM order_service_user'),
    @("Redis data volume", "infra\docker-compose.yml", 'redisdata:/data')
)
foreach ($c in $citations) {
    Check "cited: $($c[0]) ($($c[1]))" ((Src $c[1]) -match $c[2])
}

# 2. Required topics (roadmap W04 box 2 wording)
foreach ($h in "## 1. Transport versus business idempotency", "## 2. Event ordering and replay", "## 3. Schema ownership", "## 4. Redis/PostgreSQL failure boundary") {
    Check "topic defined: $h" ($doc.Contains($h))
}
Check "business idempotency covers a new MessageId for the same OrderId" ($doc -match 'new `MessageId` for the same `OrderId`')

# 3. Known gaps: each check asserts the *current* state of the code, so it
#    fails on purpose when a gap is fixed or reintroduced and the doc is not
#    updated in the same change (Week 8 fixed two, Week 9 fixed the third).
$opc = Src "src\FlashSale.OrderService\Messaging\OrderProcessedConsumer.cs"
$srp = Src "src\FlashSale.OrderService\Messaging\StockResultProcessor.cs"
$gap1 = ($srp -match 'private static bool IsAwaitingPrerequisite[\s\S]{0,400}?target == OrderState\.Completed && current == OrderState\.PendingStock') -and
        ($srp -match 'IsAwaitingPrerequisite\(order\.State, targetState\)[\s\S]{0,300}?NotYetApplicable') -and
        ($opc -match 'RequeueForRetryAsync\(') -and
        ($opc -match 'catch \(InvalidOrderStateTransitionException[\s\S]{0,600}?BasicNackAsync\([^)]*requeue: false')
Check "early OrderProcessed is requeued for bounded retry, not dead-lettered (fixed Week 9)" (
    $gap1 -and $doc.Contains("the prerequisite has not been applied yet, so the message is **requeued onto a delayed retry queue, never dead-lettered**"))
Check "design doc records the out-of-order completion fix" ($doc.Contains("**Fixed for out-of-order completion (2026-10-03, Week 9):**"))
$opp = Src "src\FlashSale.InventoryService\Messaging\OrderPlacedProcessor.cs"
Check "Order Service result processor treats only unique violations as duplicates (fixed Week 8)" (($srp -match 'PostgresErrorCodes\.UniqueViolation') -and -not ($srp -match 'catch \(DbUpdateException\)\s*\{'))
Check "design doc records the Order Service fix" ($doc.Contains("**Fixed for Order Service (2026-10-02, Week 8):**"))

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Design decisions match the code (known gaps confirmed and assigned)." -ForegroundColor Green
