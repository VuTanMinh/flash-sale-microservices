# ============================================================
# Traceability check: every requirement in the teacher brief (§4 functions,
# non-functional requirements, §5 technology table) must appear in the
# report's System Requirements / Technology Selection chapters.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-requirements-trace.ps1
#
# Each row is: brief item -> regex that must match inside the chapter.
# Exits 1 if any item is missing.
# ============================================================
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tex = Get-Content (Join-Path $repoRoot "report\report.tex") -Raw -Encoding UTF8

function Chapter([string]$name) {
    $start = $tex.IndexOf("\chapter{$name}")
    if ($start -lt 0) { throw "Chapter '$name' not found." }
    $end = $tex.IndexOf("\chapter{", $start + 10)
    return $tex.Substring($start, $end - $start)
}

$req = Chapter "System Requirements"
$tech = Chapter "Technology Selection"
$failures = 0

$requirements = [ordered]@{
    "Tiep nhan va luu order / tra order ID"            = "FR-1.*order ID"
    "Tra cuu trang thai qua polling API"               = "FR-2.*poll"
    "Reserve inventory atomically"                     = "FR-3.*atomically"
    "Cap nhat order status theo ket qua reservation"   = "FR-4.*Confirmed.*Rejected"
    "Mo phong downstream processing (Process Worker)"  = "FR-5.*Process Worker.*deterministic"
    "Publish/consume event qua RabbitMQ"               = "FR-6.*RabbitMQ"
    "Transactional Outbox tai producer"                = "FR-7.*Outbox"
    "Inbox / processed-message table tai consumer"     = "FR-8.*Inbox"
    "Retry + Dead-Letter Queue"                        = "FR-9.*dead-letter"
    "Reconciliation job (safety net)"                  = "FR-10.*safety net"
    "Inventory warm-up truoc khi mo ban"               = "FR-11.*warm-up"
    "Timestamp va trang thai tung stage"               = "FR-12.*history"
    "Duplicate/invalid event khong lap transition"     = "FR-13.*duplicate"
    "Load shedding: reject truoc khi tao order"        = "FR-14.*before an order is\s+created"
    "Consistency: inventory khong am"                  = "never goes negative"
    "Consistency: reservation <= initial inventory"    = "never exceed the\s+initial inventory"
    "Consistency: mot order khong reserve nhieu lan"   = "reserved at most once"
    "Consistency: duplicate message khong side effect" = "no duplicate side effect"
    "Performance: cau hinh EC2 / VU / duration / ..."  = "EC2 configuration, virtual users"
    "Performance: payload size + PG/Redis/RabbitMQ"    = "payload size, and the PostgreSQL, Redis and RabbitMQ"
    "Performance: ~2.000 attempts/s target"            = "2,000 reservation attempts per\s+second"
    "API vs completion throughput rieng"               = "reported separately"
    "Resilience: reject co kiem soat"                  = "controlled way"
    "Resilience: drain backlog, khong restart"         = "without a\s+full restart"
    "Observability: correlation/order/message ID"      = "correlation ID,\s+order ID, message ID"
    "Observability: state transition history"         = "state-transition history"
    "Observability: 4 timestamps"                      = "request acceptance, event publication, stock processing\s+and completion"
    "Replica tren cung host, khong multi-node"         = "same EC2 host"
    "3-5 lan, percentile/median/variation"             = "3--5 times"
}
$technologies = [ordered]@{
    "ABP Framework, .NET/C#"   = "ABP Framework"
    "RabbitMQ"                 = "RabbitMQ"
    "Redis Stack, Lua"         = "Redis Stack with Lua"
    "PostgreSQL schema-per-service" = "schema-per-service"
    "Nginx"                    = "\\item\[Nginx\]"
    "Structured logging, metrics" = "Serilog.*prometheus-net"
    "Docker Compose"           = "Docker Compose"
    "Terraform"                = "Terraform"
    "AWS EC2"                  = "EC2"
    "Apache JMeter"            = "Apache JMeter"
}

foreach ($k in $requirements.Keys) {
    if ([regex]::IsMatch($req, $requirements[$k], "Singleline")) { Write-Host "PASS  $k" -ForegroundColor Green }
    else { Write-Host "FAIL  $k  (pattern: $($requirements[$k]))" -ForegroundColor Red; $failures++ }
}
foreach ($k in $technologies.Keys) {
    if ([regex]::IsMatch($tech, $technologies[$k], "Singleline")) { Write-Host "PASS  tech: $k" -ForegroundColor Green }
    else { Write-Host "FAIL  tech: $k  (pattern: $($technologies[$k]))" -ForegroundColor Red; $failures++ }
}
# The code uses RabbitMQ.Client directly; the chapter must not claim ABP's event bus is used.
if ($tech -match "Volo\.Abp\.EventBus\.RabbitMQ" -and $tech -notmatch "\\emph\{not\} used") {
    Write-Host "FAIL  tech chapter claims ABP's RabbitMQ event bus is used" -ForegroundColor Red; $failures++
} else { Write-Host "PASS  tech chapter matches the RabbitMQ.Client implementation" -ForegroundColor Green }

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures item(s) missing." -ForegroundColor Red; exit 1 }
Write-Host "All brief requirements are traced in the report." -ForegroundColor Green
