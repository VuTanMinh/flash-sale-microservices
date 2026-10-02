# ============================================================
# Checks docs/test-plan.md (Week 4):
#  - every case row has an ID, case, roadmap box, inputs, expected outcome,
#    command, status and evidence; IDs are unique
#  - PASS only with committed evidence that actually shows a pass
#  - every roadmap week W02-W14 has at least one case
#  - unsupported "built/passed" claims are gone from the report/docs, and
#    every \unverified{TP-xx} label points at a real case
# Exits 1 on any failure.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify-test-plan.ps1
# ============================================================
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
$plan = Get-Content (Join-Path $root "docs\test-plan.md") -Encoding UTF8
$rows = @($plan | Where-Object { $_ -match '^\| TP-' } | ForEach-Object {
    $c = $_.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    [pscustomobject]@{ Id = $c[0]; Case = $c[1]; Week = $c[2]; Inputs = $c[3]; Expected = $c[4]; Command = $c[5]; Status = $c[6]; Evidence = $c[7]; Cols = $c.Count }
})
Check "test plan has cases ($($rows.Count))" ($rows.Count -ge 30)
Check "case IDs are unique" (@($rows.Id | Select-Object -Unique).Count -eq $rows.Count)

foreach ($r in $rows) {
    $complete = $r.Cols -eq 8 -and $r.Case -and $r.Week -match '^W\d\d' -and $r.Inputs -and $r.Expected -and $r.Command -and $r.Evidence
    Check "$($r.Id) has all eight fields" ([bool]$complete)
    Check "$($r.Id) status is PASS, FAIL or NOT RUN" ($r.Status -in @("PASS", "FAIL", "NOT RUN"))
    if ($r.Status -eq "PASS") {
        $path = ($r.Evidence -replace '`', '')
        $full = Join-Path $root $path
        $tracked = [bool](git -C $root ls-files --error-unmatch $path 2>$null)
        $shows = $false
        if (Test-Path $full) {
            $text = Get-Content $full -Raw -Encoding UTF8
            switch -Regex ($path) {
                '\.trx$'  { $shows = $text -match 'failed="0"' -and $text -match 'passed="[1-9]' }
                '\.log$'  { $shows = ($text -match 'Exit code: 0' -or $text -match 'repeatable and seeds the exact') -and $text -notmatch '(?m)^FAIL' }
                '\.json$' { $shows = $text -match '"verdict":\s*"(PASS|RACE CAPTURED)"' }
                '\.md$'   { $shows = $text -notmatch 'FAIL' -and $text -match 'PASS|RACE CAPTURED' }
            }
        }
        Check "$($r.Id) PASS has committed evidence that shows a pass ($path)" ($tracked -and $shows)
        $script = [regex]::Match($r.Command, 'scripts/[\w-]+\.ps1').Value
        if ($script) { Check "$($r.Id) command script exists ($script)" (Test-Path (Join-Path $root $script)) }
    } else {
        Check "$($r.Id) without PASS claims no evidence" ($r.Evidence -eq "—")
    }
}
foreach ($w in 2..14) {
    $tag = "W{0:D2}" -f $w
    Check "roadmap $tag has at least one case" (@($rows | Where-Object { $_.Week -match $tag }).Count -ge 1)
}

# Unsupported claims removed / labelled
$tex = Get-Content (Join-Path $root "report\report.tex") -Raw -Encoding UTF8
foreach ($stale in "Passed: 14, Skipped: 0, Total: 14", "Full suite: 19/19 passing", "each verified live above or in an earlier week", "14 unit tests") {
    Check "report no longer claims '$stale'" (-not $tex.Contains($stale))
}
$labels = @([regex]::Matches($tex, '\\unverified\{(TP-[A-Z]\d\d)\}') | ForEach-Object { $_.Groups[1].Value })
# Labels disappear as their cases get real evidence (e.g. TP-I02 in Week 7), so
# there is no fixed count -- but a label must never point at a case that is
# already PASS: then the text should cite the evidence instead.
Check "report still labels the remaining unsupported manual-run claims ($($labels.Count))" ($labels.Count -ge 1)
foreach ($l in $labels | Select-Object -Unique) {
    $passed = @($rows | Where-Object { $_.Id -eq $l -and $_.Status -eq "PASS" }).Count -gt 0
    Check "report label $l does not point at a case that already passed" (-not $passed)
}
foreach ($l in $labels | Select-Object -Unique) { Check "report label $l is a test-plan case" ($rows.Id -contains $l) }
$seq = Get-Content (Join-Path $root "docs\sequence-diagrams.md") -Raw -Encoding UTF8
Check "sequence diagrams: 'Verified live' claims carry a not-re-verified note" (@([regex]::Matches($seq, 'Verified live')).Count -eq @([regex]::Matches($seq, 'Not re-verified')).Count)
Check "sequence diagrams header no longer says 'verified live'" (-not $seq.Contains("actually built and verified live"))

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Test plan is complete and every PASS is backed by committed evidence." -ForegroundColor Green
