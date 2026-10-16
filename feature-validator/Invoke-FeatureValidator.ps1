<#
.SYNOPSIS
  Read-only feature validator for Azure Virtual Desktop session hosts and Windows 365
  Cloud PCs. Reports, per feature, whether it can work on this host and what blocks it.

.DESCRIPTION
  Run ON the session host / Cloud PC. Elevation recommended (some machine state is only
  readable elevated); everything it does is a read.

  Colours: FAIL red, WARN yellow, ERROR magenta, PASS green, INFO cyan, SKIP grey.
  FAIL = the feature cannot work as configured. WARN = it works, but degraded or about
  to break. Use -NoColor for plain text (logs, tickets).

  Writes JSON to %ProgramData%\FeatureValidator\latest.json (falls back to
  %LOCALAPPDATA% when not elevated), or to -OutputPath.

  Exit 0 = no FAIL/ERROR (WARN does not fail the run). Exit 1 = at least one FAIL/ERROR.

.PARAMETER Feature
  Only run checks for these features (e.g. Redirection). Default: all.

.PARAMETER Connect
  Also run cloud-side checks (Entra / Intune via Graph). Not implemented yet; cloud
  checks are listed as SKIP so you can see what is coming.

.PARAMETER Platform
  Override platform detection: AVD, W365 or Auto (default).

.PARAMETER Fixture
  Path to a JSON fixture. Replaces every probe with fixture data and touches no system
  state. Used by the offline tests and for reproducing a customer's report.

.EXAMPLE
  .\Invoke-FeatureValidator.ps1
.EXAMPLE
  .\Invoke-FeatureValidator.ps1 -Feature Redirection -ShowSkipped
#>
[CmdletBinding()]
param(
    [string[]]$Feature,
    [switch]$Connect,
    [ValidateSet('Auto', 'AVD', 'W365')][string]$Platform = 'Auto',
    [string]$OutputPath,
    [string]$Fixture,
    [switch]$NoColor,
    [switch]$ShowSkipped
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Engine.ps1')

$fx = $null
if ($Fixture) {
    $raw = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json
    $fx = @{ Probes = @{} }
    if ($raw.Platform) { $fx.Platform = "$($raw.Platform)" }
    if ($raw.Probes) { foreach ($p in $raw.Probes.PSObject.Properties) { $fx.Probes[$p.Name] = $p.Value } }
}

$checks = Import-CheckCatalog -Path (Join-Path $PSScriptRoot 'checks')
if ($Feature) { $checks = @($checks | Where-Object { $Feature -contains $_.Feature }) }
if (-not $checks) { Write-Host "No checks match -Feature $($Feature -join ',')" -ForegroundColor Yellow; exit 1 }

$hostPlatform = $Platform
if ($Platform -eq 'Auto') { $hostPlatform = Get-HostPlatform -Fixture $fx }

$results = @(foreach ($c in $checks) { Invoke-Check -Check $c -Platform $hostPlatform -Connect:$Connect -Fixture $fx })

$counts = Write-Report -Results $results -Platform $hostPlatform -NoColor:$NoColor -ShowSkipped:$ShowSkipped
if ($hostPlatform -eq 'Unknown') {
    Write-Host 'Platform not detected; checks for both AVD and W365 were run. Use -Platform to set it.' -ForegroundColor Yellow
}

$report = [ordered]@{
    Tool      = 'feature-validator'
    Version   = '0.1.0'
    Timestamp = (Get-Date).ToString('o')
    Computer  = $env:COMPUTERNAME
    Platform  = $hostPlatform
    Fixture   = [bool]$Fixture
    Summary   = $counts
    Results   = $results
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:ProgramData 'FeatureValidator\latest.json'
    try {
        New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText($OutputPath, '')
    } catch {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'FeatureValidator\latest.json'
    }
}
New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "JSON: $OutputPath`n"

exit (Get-ExitCode -Results $results)
