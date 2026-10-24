# ============================================================
# Week 12 box 1 (C3): set or remove the flashsale-c3-bounds RabbitMQ policy
# that caps the six main input queues with max-length + overflow=reject-publish.
#
#   powershell -File .\scripts\set-queue-bounds.ps1 -Container <rabbit> -MaxLength 3
#   powershell -File .\scripts\set-queue-bounds.ps1 -Container <rabbit> -Remove
#   powershell -File .\scripts\set-queue-bounds.ps1 -Container <rabbit> -Inspect
#
# <rabbit> is the RabbitMQ container name. When the container publishes its
# management port (15672), the policy is applied through the management API: the
# host port is discovered from the container's own mapping, using the
# flashsale/flashsale_dev account both the Compose and the throwaway brokers use
# (local and throwaway brokers publish 15672; scripts/verify-load-shedding.ps1
# relies on this path). When the container has NO 15672 mapping -- the EC2 stack
# where only Nginx publishes a host port and the broker uses ${RABBITMQ_PASSWORD}
# -- the policy is applied with `rabbitmqctl` inside the container instead: no
# port and no credentials. The JSON definition is neither a plain native
# argument (PowerShell 5.1 strips its embedded double quotes) nor piped on
# stdin (PowerShell 5.1 adds a BOM and CRLF): it is passed base64-encoded and
# decoded in the container; the pattern is single-quoted so its `|`, `(`, `)`
# and `$` stay literal. -Inspect prints `rabbitmqctl list_policies` and
# `rabbitmqctl list_queues name policy messages_ready messages_unacknowledged`.
# Neither path prints a password (the rabbitmqctl path needs none).
#
# The pattern matches ONLY the six main input queues -- never a .dlq or a
# .retry.N queue:
#   OrderPlaced, StockReserved, StockRejected, ProcessWorker.StockReserved,
#   OrderProcessingStarted, OrderProcessed
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Container,
    [int]$MaxLength = 0,
    [switch]$Remove,
    [switch]$Inspect
)
$ErrorActionPreference = "Continue"

$PolicyName = "flashsale-c3-bounds"
$Pattern = '^(OrderPlaced|StockReserved|StockRejected|ProcessWorker\.StockReserved|OrderProcessingStarted|OrderProcessed)$'

if ($Inspect) {
    Write-Output "Policies (rabbitmqctl list_policies):"
    @(docker exec $Container rabbitmqctl list_policies 2>&1) | ForEach-Object { Write-Output $_ }
    Write-Output "Queues (rabbitmqctl list_queues name policy messages_ready messages_unacknowledged):"
    @(docker exec $Container rabbitmqctl list_queues name policy messages_ready messages_unacknowledged 2>&1) | ForEach-Object { Write-Output $_ }
    exit 0
}

if (-not $Remove -and $MaxLength -lt 1) {
    Write-Output "usage: set-queue-bounds.ps1 -Container <rabbit> -MaxLength <n> [-Remove] [-Inspect]"
    exit 2
}

# Discover whether the container publishes the management port (15672).
$portLine = @(docker port $Container 15672 2>$null)
$hasMgmtPort = ($portLine.Count -gt 0)

if ($hasMgmtPort) {
    # ---- management API path (local and throwaway brokers publish 15672) ----
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
} else {
    # ---- rabbitmqctl path (EC2: no 15672 mapping, ${RABBITMQ_PASSWORD}) ----
    # No credentials and no published port are needed. The pattern is
    # single-quoted so its regex metacharacters stay literal in the container
    # shell.
    if ($Remove) {
        @(docker exec $Container rabbitmqctl clear_policy $PolicyName 2>&1) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Policy '$PolicyName' was not present (nothing removed)."
        } else {
            Write-Output "Removed policy '$PolicyName'."
        }
    } else {
        $definition = @{ "max-length" = $MaxLength; overflow = "reject-publish" } | ConvertTo-Json -Depth 6 -Compress
        # The JSON goes in base64 as part of the command, not on stdin: Windows
        # PowerShell 5.1 prefixes piped text with a UTF-8 BOM and ends it with
        # CRLF, which rabbitmqctl rejects as JSON. Base64 has no quotes or
        # spaces, so it also survives PowerShell 5.1's native-argument quoting.
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($definition))
        $script = 'rabbitmqctl set_policy ' + $PolicyName + " '" + $Pattern + "' " + '$(echo ' + $b64 + ' | base64 -d) --apply-to queues --priority 0'
        $out = @(docker exec $Container sh -c $script 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-Output "ERROR: could not set policy '$PolicyName': $($out -join ' ')"
            exit 1
        }
        Write-Output "Set policy '$PolicyName' (max-length=$MaxLength, overflow=reject-publish) on the six main queues."
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
