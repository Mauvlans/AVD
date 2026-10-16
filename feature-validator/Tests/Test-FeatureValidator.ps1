<#
    Offline tests for the feature validator.

    What they prove: the catalog is well-formed, the evaluation logic is right (including
    the inverted "Do not allow ... = 1 means BLOCKED" semantics), FAIL vs WARN map to the
    right statuses and exit codes, and end-to-end runs against fixtures give the expected
    report. What they do NOT prove: that a real host exposes these values where the
    catalog looks. That needs a run on a real Cloud PC and a real AVD session host.

    Run:  pwsh -File ./Tests/Test-FeatureValidator.ps1
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $root 'lib') 'Engine.ps1')

$script:Pass = 0
$script:Fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -ceq "$Actual") {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green; $script:Pass++
    } else {
        Write-Host ("  FAIL  {0}`n        expected '{1}'`n        actual   '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:Fail++
    }
}

Write-Host "`nCatalog" -ForegroundColor Cyan
$checks = Import-CheckCatalog -Path (Join-Path $root 'checks')
Assert-Equal 'catalog loads checks' $true ($checks.Count -gt 0)
Assert-Equal 'every check id unique' $checks.Count (@($checks | ForEach-Object Id | Sort-Object -Unique).Count)
Assert-Equal 'every Local check has exactly one Expect' 0 (@($checks | Where-Object { $_.Scope -eq 'Local' -and $_.Expect.Count -ne 1 }).Count)

Write-Host "`nSchema rejects bad checks" -ForegroundColor Cyan
$good = @{ Id='X-1'; Feature='F'; Title='T'; Platform='Both'; Scope='Local'; Severity='Fail'; WhenFailed='w'; DocLink='https://x'
           Probe=@{ Type='Registry'; Path='HKLM:\X'; Name='v' }; Expect=@{ Equal=1 } }
Assert-Equal 'valid check has no problems' 0 (@(Test-CheckDefinition -Check $good).Count)
$bad = $good.Clone(); $bad.Severity = 'Critical'
Assert-Equal 'unknown severity rejected' 1 (@(Test-CheckDefinition -Check $bad).Count)
$bad = $good.Clone(); $bad.Expect = @{ GreaterThan = 1 }
Assert-Equal 'unknown Expect operator rejected' 1 (@(Test-CheckDefinition -Check $bad).Count)
$bad = $good.Clone(); $bad.Expect = @{ Equal = 1; NotEqual = 2 }
Assert-Equal 'two Expect operators rejected' 1 (@(Test-CheckDefinition -Check $bad).Count)
$bad = $good.Clone(); $bad.DocLink = 'http://x'
Assert-Equal 'non-https DocLink rejected' 1 (@(Test-CheckDefinition -Check $bad).Count)
$bad = $good.Clone(); $bad.Scope = 'Cloud'
Assert-Equal 'Cloud scope with local probe rejected' 1 (@(Test-CheckDefinition -Check $bad).Count)
$bad = $good.Clone(); $bad.Remove('DocLink')
Assert-Equal 'missing DocLink rejected' 1 (@(Test-CheckDefinition -Check $bad).Count)

Write-Host "`nExpectation logic (inverted 'Do not allow' semantics)" -ForegroundColor Cyan
Assert-Equal 'fDisableClip=1 does NOT satisfy NotEqual 1 (blocked)'    $false (Test-Expectation -Observed 1 -Expect @{ NotEqual = 1 })
Assert-Equal 'fDisableClip=0 satisfies NotEqual 1 (allowed)'           $true  (Test-Expectation -Observed 0 -Expect @{ NotEqual = 1 })
Assert-Equal 'fDisableClip absent satisfies NotEqual 1 (not configured)' $true (Test-Expectation -Observed $null -Expect @{ NotEqual = 1 })
Assert-Equal 'absent does NOT satisfy Equal'       $false (Test-Expectation -Observed $null -Expect @{ Equal = 'Running' })
Assert-Equal 'Running satisfies Equal Running'     $true  (Test-Expectation -Observed 'Running' -Expect @{ Equal = 'Running' })
Assert-Equal 'Exists on value'                     $true  (Test-Expectation -Observed 'Stopped' -Expect @{ Exists = $true })
Assert-Equal 'Exists on absent'                    $false (Test-Expectation -Observed $null -Expect @{ Exists = $true })
Assert-Equal 'NotExists on absent'                 $true  (Test-Expectation -Observed $null -Expect @{ NotExists = $true })
Assert-Equal 'In matches'                          $true  (Test-Expectation -Observed 2 -Expect @{ In = @(1, 2, 3) })
Assert-Equal 'In rejects'                          $false (Test-Expectation -Observed 5 -Expect @{ In = @(1, 2, 3) })
Assert-Equal 'MinVersion equal passes'             $true  (Test-Expectation -Observed '1.2.3.4' -Expect @{ MinVersion = '1.2.3.4' })
Assert-Equal 'MinVersion lower fails'              $false (Test-Expectation -Observed '1.2.3' -Expect @{ MinVersion = '1.10' })
Assert-Equal 'MinVersion compares numerically'     $true  (Test-Expectation -Observed '1.10' -Expect @{ MinVersion = '1.9' })
Assert-Equal 'MinVersion garbage fails closed'     $false (Test-Expectation -Observed 'abc' -Expect @{ MinVersion = '1.0' })

Write-Host "`nStatus mapping and exit codes" -ForegroundColor Cyan
$warnCheck = $good.Clone(); $warnCheck.Severity = 'Warn'
$fx = @{ Platform = 'AVD'; Probes = @{ 'Registry|HKLM:\X|v' = 0 } }
Assert-Equal 'failed Fail check -> Fail'  'Fail' (Invoke-Check -Check $good -Platform 'AVD' -Fixture $fx).Status
Assert-Equal 'failed Warn check -> Warn'  'Warn' (Invoke-Check -Check $warnCheck -Platform 'AVD' -Fixture $fx).Status
$fx.Probes['Registry|HKLM:\X|v'] = 1
Assert-Equal 'satisfied check -> Pass'    'Pass' (Invoke-Check -Check $good -Platform 'AVD' -Fixture $fx).Status
$w365Only = $good.Clone(); $w365Only.Platform = 'W365'
Assert-Equal 'W365 check on AVD -> Skipped'  'Skipped' (Invoke-Check -Check $w365Only -Platform 'AVD' -Fixture $fx).Status
Assert-Equal 'W365 check on Unknown -> runs' 'Pass'    (Invoke-Check -Check $w365Only -Platform 'Unknown' -Fixture $fx).Status
$cloud = $good.Clone(); $cloud.Scope = 'Cloud'; $cloud.Probe = @{ Type = 'Cloud'; Query = 'q' }; $cloud.Remove('Expect')
Assert-Equal 'Cloud check without -Connect -> Skipped' 'Skipped' (Invoke-Check -Check $cloud -Platform 'AVD' -Fixture $fx).Status

$mk = { param($s) [pscustomobject]@{ Status = $s } }
Assert-Equal 'exit 0 when only Pass/Warn/Info/Skipped' 0 (Get-ExitCode -Results @((& $mk 'Pass'), (& $mk 'Warn'), (& $mk 'Info'), (& $mk 'Skipped')))
Assert-Equal 'exit 1 on any Fail'  1 (Get-ExitCode -Results @((& $mk 'Pass'), (& $mk 'Fail')))
Assert-Equal 'exit 1 on any Error' 1 (Get-ExitCode -Results @((& $mk 'Warn'), (& $mk 'Error')))
Assert-Equal 'Fail and Warn use different colours' $true ($script:StatusStyle.Fail.Color -ne $script:StatusStyle.Warn.Color)

Write-Host "`nSingle-file build is current" -ForegroundColor Cyan
$dist = Join-Path (Join-Path $root 'dist') 'Invoke-FeatureValidator.ps1'
Assert-Equal 'dist file exists (run build/Build-Standalone.ps1)' $true (Test-Path $dist)
$distText = ''
if (Test-Path $dist) { $distText = Get-Content -Raw -LiteralPath $dist }
$norm = { param($t) ($t -replace "`r`n", "`n").Trim() }
Assert-Equal 'dist contains current lib/Engine.ps1' $true ((& $norm $distText).Contains((& $norm (Get-Content -Raw (Join-Path (Join-Path $root 'lib') 'Engine.ps1')))))
foreach ($f in (Get-ChildItem (Join-Path $root 'checks') -Filter *.psd1)) {
    Assert-Equal "dist contains current checks/$($f.Name)" $true ((& $norm $distText).Contains((& $norm (Get-Content -Raw $f.FullName))))
}
$mainBody = (& $norm (Get-Content -Raw (Join-Path $root 'Invoke-FeatureValidator.ps1'))) -replace '(?s)#region ENGINE.*?#endregion ENGINE', ''
$distBody = (& $norm $distText) -replace '(?s)#region ENGINE.*?#endregion ENGINE', ''
Assert-Equal 'dist main body matches Invoke-FeatureValidator.ps1' $true ($mainBody -eq $distBody)
Assert-Equal 'dist does not dot-source lib/Engine.ps1' $false ($distText -match 'Join-Path \$PSScriptRoot ''lib''')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("fv-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$shell = (Get-Process -Id $PID).Path
function Invoke-Scenario([string]$Script, [string]$Name) {
    $out = Join-Path $tmp ("{0}-{1}.json" -f $Name, [guid]::NewGuid())
    $fixture = Join-Path (Join-Path $PSScriptRoot 'fixtures') "$Name.json"
    & $shell -NoProfile -File $Script -Fixture $fixture -OutputPath $out -NoColor *> $null
    $code = $LASTEXITCODE
    $rep = Get-Content $out -Raw | ConvertFrom-Json
    return @{ Code = $code; Report = $rep }
}
function Get-StatusOf($rep, $id) { ($rep.Results | Where-Object Id -eq $id).Status }

$targets = [ordered]@{ 'repo' = (Join-Path $root 'Invoke-FeatureValidator.ps1'); 'single-file' = $dist }
foreach ($t in $targets.Keys) {
    Write-Host "`nEnd-to-end against fixtures ($t)" -ForegroundColor Cyan
    $script = $targets[$t]

    $s = Invoke-Scenario $script 'w365-secure-default'
    Assert-Equal "[$t] secure-default: exit 1"            1 $s.Code
    Assert-Equal "[$t] secure-default: 4 Fail"            4 $s.Report.Summary.Fail
    Assert-Equal "[$t] secure-default: REDIR-001 Fail"    'Fail' (Get-StatusOf $s.Report 'REDIR-001')
    Assert-Equal "[$t] secure-default: platform W365"     'W365' $s.Report.Platform

    $s = Invoke-Scenario $script 'healthy'
    Assert-Equal "[$t] healthy: exit 0"                   0 $s.Code
    Assert-Equal "[$t] healthy: no Fail"                  0 $s.Report.Summary.Fail
    Assert-Equal "[$t] healthy: no Warn"                  0 $s.Report.Summary.Warn
    Assert-Equal "[$t] healthy: cloud checks skipped"     3 $s.Report.Summary.Skipped

    $s = Invoke-Scenario $script 'directional-clipboard'
    Assert-Equal "[$t] directional: exit 0 (warn only)"   0 $s.Code
    Assert-Equal "[$t] directional: REDIR-005 Warn"       'Warn' (Get-StatusOf $s.Report 'REDIR-005')
    Assert-Equal "[$t] directional: REDIR-006 Pass"       'Pass' (Get-StatusOf $s.Report 'REDIR-006')

    $s = Invoke-Scenario $script 'listener-block'
    Assert-Equal "[$t] listener: exit 1"                  1 $s.Code
    Assert-Equal "[$t] listener: REDIR-001 Pass (policy clean)" 'Pass' (Get-StatusOf $s.Report 'REDIR-001')
    Assert-Equal "[$t] listener: REDIR-007 Fail"          'Fail' (Get-StatusOf $s.Report 'REDIR-007')

    $s = Invoke-Scenario $script 'termservice-stopped'
    Assert-Equal "[$t] termservice: REDIR-009 Fail"       'Fail' (Get-StatusOf $s.Report 'REDIR-009')
    Assert-Equal "[$t] termservice: REDIR-010 Fail (missing)" 'Fail' (Get-StatusOf $s.Report 'REDIR-010')
}

Write-Host "`nSingle file is safe to download and run" -ForegroundColor Cyan
$bytes = [IO.File]::ReadAllBytes($dist)
Assert-Equal 'dist has no UTF-8 BOM (breaks irm + scriptblock)' $false ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Assert-Equal 'dist is pure ASCII (safe for PowerShell 5.1)' 0 (@($bytes | Where-Object { $_ -gt 127 }).Count)
# Parse exactly what irm would hand over: the raw bytes decoded without BOM stripping.
$asDownloaded = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
$parsed = $true
try { [scriptblock]::Create($asDownloaded) | Out-Null } catch { $parsed = $false }
Assert-Equal 'dist parses as a downloaded string' $true $parsed

Write-Host "`nSingle file via scriptblock (irm style)" -ForegroundColor Cyan
$fx = Join-Path (Join-Path $PSScriptRoot 'fixtures') 'w365-secure-default.json'
$out = Join-Path $tmp 'sb.json'
$probe = "& ([scriptblock]::Create([IO.File]::ReadAllText('$dist'))) -Fixture '$fx' -OutputPath '$out' -NoColor *> `$null; 'alive'; `$LASTEXITCODE"
$res = @(& $shell -NoProfile -Command $probe)
Assert-Equal 'scriptblock run does not exit the host' 'alive' $res[0]
Assert-Equal 'scriptblock run sets $LASTEXITCODE = 1' '1' $res[1]
$res2 = @(& $shell -NoProfile -Command $probe2)

Remove-Item -Recurse -Force $tmp

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit ([int]($script:Fail -gt 0))
