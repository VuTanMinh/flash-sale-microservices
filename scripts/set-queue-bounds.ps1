# ============================================================
# Week 12 box 1 (C3): set or remove the flashsale-c3-bounds RabbitMQ policy
# that caps the six main input queues with max-length + overflow=reject-publish.
#
#   powershell -File .\scripts\set-queue-bounds.ps1 -Container <rabbit> -MaxLength 3
#   powershell -File .\scripts\set-queue-bounds.ps1 -Container <rabbit> -Remove
#
# <rabbit> is the RabbitMQ container name. The policy is applied through the
# management API (the host port is discovered from the container's own 15672
# mapping, and the flashsale/flashsale_dev account both the Compose and the
# throwaway brokers use); it is NOT set with `rabbitmqctl set_policy` because
# that command takes a JSON definition whose embedded double quotes PowerShell
# 5.1 strips from native arguments. The effective policy is then printed from
# `rabbitmqctl list_queues name policy`, which is the canonical source.
#
# The pattern matches ONLY the six main input queues -- never a .dlq or a
# .retry.N queue:
#   OrderPlaced, StockReserved, StockRejected, ProcessWorker.StockReserved,
#   OrderProcessingStarted, OrderProcessed
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$MaxLength = 0,
    [switch]$Remove
)
$ErrorActionPreference = "Continue"

$PolicyName = "flashsale-c3-bounds"
$Pattern = '^(OrderPlaced|StockReserved|StockRejected|ProcessWorker\.StockReserved|OrderProcessingStarted|OrderProcessed)$'

if (-not $Remove -and $MaxLength -lt 1) {
    Write-Output "usage: set-queue-bounds.ps1 -Container <rabbit> -MaxLength <n> [-Remove]"
    exit 2
}

# Discover the host management port from the container's own mapping.
$portLine = @(docker port $Container 15672 2>$null)
if ($portLine.Count -eq 0) {
    Write-Output "ERROR: cannot read the 15672 port mapping for container '$Container' (is it running?)"
    exit 1
}
$mgmt = ($portLine[0] -split ":")[-1]
$auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("flashsale:flashsale_dev")) }
$api = "http://localhost:$mgmt/api"

if ($Remove) {
    try {
        Invoke-RestMethod -Method Delete -Headers $auth -Uri "$api/policies/%2F/$PolicyName" -TimeoutSec 10 | Out-Null
        Write-Output "Removed policy '$PolicyName'."
    } catch {
        Write-Output "Policy '$PolicyName' was not present (nothing removed)."
    }
} else {
    $body = @{
        pattern    = $Pattern
        definition = @{ "max-length" = $MaxLength; overflow = "reject-publish" }
        priority   = 0
        "apply-to" = "queues"
    }
    try {
        Invoke-RestMethod -Method Put -Headers $auth -Uri "$api/policies/%2F/$PolicyName" `
            -Body ($body | ConvertTo-Json -Depth 6 -Compress) -ContentType "application/json" -TimeoutSec 10 | Out-Null
        Write-Output "Set policy '$PolicyName' (max-length=$MaxLength, overflow=reject-publish) on the six main queues."
    } catch {
        Write-Output "ERROR: could not set policy '$PolicyName': $($_.Exception.Message)"
        exit 1
    }
}

# Print the effective policy per queue from rabbitmqctl (the canonical source).
Write-Output "Effective policy per queue (rabbitmqctl list_queues name policy):"
$lines = @(docker exec $Container rabbitmqctl -q list_queues name policy --no-table-headers 2>$null)
foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = @($line -split "`t")
    $name = $parts[0]
    $policy = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1] } else { "-" }
    Write-Output ("  {0,-32} {1}" -f $name, $policy)
}
exit 0
