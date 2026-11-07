param(
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [Parameter(Mandatory = $true)][string]$ScriptFile,
    [int]$TimeoutSeconds = 1800,
    [string]$OutFile = "",
    [string]$AwsExe = "C:\Users\Lenovo\AppData\Local\Programs\Amazon\AWSCLIV2\aws.exe",
    [string]$AwsProfile = "flashsale-plan"
)
# Runs a bash script on an EC2 instance via SSM Run Command (read-only profile
# + the FlashSaleRunCommands inline policy) and prints its output and status.
# Used by ec2-session.ps1.
$ErrorActionPreference = "Continue"
$aws = $AwsExe
$lines = [string[]]([IO.File]::ReadAllLines($ScriptFile))
$params = @{ commands = @($lines); executionTimeout = @("$TimeoutSeconds") } | ConvertTo-Json -Compress -Depth 4
$pfile = Join-Path $env:TEMP ("ssm-params-" + [guid]::NewGuid() + ".json")
[IO.File]::WriteAllText($pfile, $params)
$cid = & $aws ssm send-command --profile $AwsProfile --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters "file://$pfile" --timeout-seconds 600 --query 'Command.CommandId' --output text
Remove-Item $pfile
if (-not $cid) { Write-Output "SEND FAILED"; exit 2 }
Write-Output "command $cid"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds + 120)
do {
    Start-Sleep 5
    $inv = & $aws ssm get-command-invocation --profile $AwsProfile --command-id $cid --instance-id $InstanceId --output json 2>$null | ConvertFrom-Json
} while ($inv -and $inv.Status -in 'Pending', 'InProgress', 'Delayed' -and (Get-Date) -lt $deadline)
Write-Output "status $($inv.Status) exit $($inv.ResponseCode)"
Write-Output "--- stdout (last 24000 chars) ---"
Write-Output $inv.StandardOutputContent
if ($inv.StandardErrorContent) { Write-Output "--- stderr ---"; Write-Output $inv.StandardErrorContent }
if ($OutFile) { @("command $cid", "status $($inv.Status) exit $($inv.ResponseCode)", $inv.StandardOutputContent, "--- stderr ---", $inv.StandardErrorContent) | Out-File -Encoding utf8 $OutFile }
