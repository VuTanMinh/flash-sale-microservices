param(
    [Parameter(Mandatory = $true)][ValidateSet("get", "put")][string]$Mode,
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$LocalPath,
    [string]$AwsExe = "C:\Users\Lenovo\AppData\Local\Programs\Amazon\AWSCLIV2\aws.exe",
    [string]$AwsProfile = "flashsale-plan"
)
# Copies one file to or from an EC2 instance through SSM Run Command only (no
# SSH, no S3), with the read-only profile + FlashSaleRunCommands policy. The
# file travels gzip + base64 in chunks (a command's output is cut at 24,000
# characters) and is checked against the sha256 printed on the host.
# Used by ec2-session.ps1.
$ErrorActionPreference = "Stop"
$aws = $AwsExe

function Run([string[]]$lines) {
    $params = @{ commands = @($lines); executionTimeout = @("600") } | ConvertTo-Json -Compress -Depth 4
    $pfile = Join-Path $env:TEMP ("ssmf-" + [guid]::NewGuid() + ".json")
    [IO.File]::WriteAllText($pfile, $params)
    $cid = & $aws ssm send-command --profile $AwsProfile --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters "file://$pfile" --query 'Command.CommandId' --output text
    Remove-Item $pfile
    if (-not $cid) { throw "send-command failed" }
    do {
        Start-Sleep 2
        $inv = & $aws ssm get-command-invocation --profile $AwsProfile --command-id $cid --instance-id $InstanceId --output json 2>$null | ConvertFrom-Json
    } while (-not $inv -or $inv.Status -in 'Pending', 'InProgress', 'Delayed')
    if ($inv.Status -ne 'Success') { throw "command $cid ended $($inv.Status): $($inv.StandardErrorContent)" }
    return [string]$inv.StandardOutputContent
}
function Sha256([byte[]]$b) { return -join ([Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString("x2") }) }
function Gzip([byte[]]$b) { $ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress); $gz.Write($b, 0, $b.Length); $gz.Close(); return $ms.ToArray() }
function Gunzip([byte[]]$b) { $in = New-Object IO.MemoryStream(, $b); $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress); $out = New-Object IO.MemoryStream; $gz.CopyTo($out); return $out.ToArray() }

if ($Mode -eq "get") {
    $info = Run @("set -e", "gzip -c '$RemotePath' | base64 -w0 > /tmp/ssmf.b64", "echo SIZE `$(stat -c %s /tmp/ssmf.b64) SHA `$(sha256sum '$RemotePath' | cut -d' ' -f1)")
    if ($info -notmatch 'SIZE (\d+) SHA ([0-9a-f]{64})') { throw "bad info: $info" }
    $size = [int]$Matches[1]; $sha = $Matches[2]
    $sb = New-Object Text.StringBuilder
    for ($off = 0; $off -lt $size; $off += 20000) {
        $chunk = Run @("tail -c +$($off + 1) /tmp/ssmf.b64 | head -c 20000")
        [void]$sb.Append($chunk.Trim())
    }
    $bytes = Gunzip ([Convert]::FromBase64String($sb.ToString()))
    $got = Sha256 $bytes
    if ($got -ne $sha) { throw "sha256 mismatch: host $sha local $got" }
    [IO.File]::WriteAllBytes($LocalPath, $bytes)
    Run @("rm -f /tmp/ssmf.b64") | Out-Null
    Write-Output "got $RemotePath -> $LocalPath ($($bytes.Length) bytes, sha256 $sha, $([math]::Ceiling($size / 20000)) chunks)"
} else {
    $bytes = [IO.File]::ReadAllBytes($LocalPath); $sha = Sha256 $bytes
    $b64 = [Convert]::ToBase64String((Gzip $bytes))
    Run @(": > /tmp/ssmf-up.b64") | Out-Null
    for ($off = 0; $off -lt $b64.Length; $off += 24000) {
        $part = $b64.Substring($off, [Math]::Min(24000, $b64.Length - $off))
        $lines = @(); for ($i = 0; $i -lt $part.Length; $i += 6000) { $lines += "printf '%s' '" + $part.Substring($i, [Math]::Min(6000, $part.Length - $i)) + "' >> /tmp/ssmf-up.b64" }
        Run $lines | Out-Null
    }
    $res = Run @("set -e", "base64 -d /tmp/ssmf-up.b64 | gunzip > '$RemotePath'", "rm -f /tmp/ssmf-up.b64", "sha256sum '$RemotePath' | cut -d' ' -f1")
    if ($res.Trim() -ne $sha) { throw "sha256 mismatch after upload: local $sha host $($res.Trim())" }
    Write-Output "put $LocalPath -> $RemotePath ($($bytes.Length) bytes, sha256 $sha)"
}
