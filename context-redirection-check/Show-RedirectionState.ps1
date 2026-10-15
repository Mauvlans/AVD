<#
.SYNOPSIS
  Shows which RDP redirections the current Cloud PC / session host session actually received,
  and whether device policy is blocking them. Read-only. Built for demoing and troubleshooting
  context-based redirection (Windows 365 Remote Connection Experience / AVD host pool RDP
  properties tied to an Entra authentication context).

.DESCRIPTION
  Run INSIDE the remote session as the signed-in user. No elevation needed.

  Layer 1 - Device policy. Reads fDisableClip / fDisableCdm / fDisableCpm / fDisablePNPRedir
  under HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services. A value of 1 is a hard
  block that context-based redirection can never override (most restrictive wins).

  Layer 2 - What this session got. Context-based redirection is decided by the service per
  connection; Windows keeps no documented local record of the auth-context result. So the
  session's live state is the proof: rdpclip running in this session, \\tsclient drives,
  "(redirected)" printers, redirected PnP/USB devices.

  Writes $env:LOCALAPPDATA\ContextRedirectionCheck\latest.json.
  Exit 0 = no device-policy block; exit 1 = device policy blocks at least one redirection.
  Session-level BLOCKED is not an error - that is the expected result from a non-compliant
  client.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Show-RedirectionState.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# ---- Layer 1: device policy -------------------------------------------------------------
$tsKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$pol   = Get-ItemProperty -Path $tsKey

function Get-PolicyState([string]$ValueName) {
    $v = $pol.$ValueName
    if ($null -eq $v) { return 'NotConfigured' }
    if ($v -eq 1)     { return 'Blocked' }
    return 'Allowed'
}

$policy = [ordered]@{
    Clipboard = Get-PolicyState 'fDisableClip'
    Drives    = Get-PolicyState 'fDisableCdm'
    Printers  = Get-PolicyState 'fDisableCpm'
    PnP_USB   = Get-PolicyState 'fDisablePNPRedir'
}

# ---- Layer 2: what this session received -----------------------------------------------
$mySession = (Get-Process -Id $PID).SessionId

$clipOk   = [bool](Get-Process -Name rdpclip | Where-Object SessionId -eq $mySession)
$drvOk    = Test-Path '\\tsclient'
$drvList  = if ($drvOk) { @(Get-ChildItem '\\tsclient' | ForEach-Object Name) } else { @() }
$printers = @(Get-Printer | Where-Object Name -match 'redirected' | ForEach-Object Name)
# Best effort: redirected PnP/USB devices enumerate under RDP/TS buses.
$usb      = @(Get-PnpDevice -PresentOnly | Where-Object InstanceId -match '^(TSUSB|TSBUS|SWD\\RDP)' |
              ForEach-Object FriendlyName)

$session = [ordered]@{
    Clipboard = [ordered]@{ Allowed = $clipOk;              Detail = $(if ($clipOk) { 'rdpclip running in this session' } else { 'no rdpclip in this session' }) }
    Drives    = [ordered]@{ Allowed = $drvOk;               Detail = ($drvList -join ', ') }
    Printers  = [ordered]@{ Allowed = ($printers.Count -gt 0); Detail = ($printers -join ', ') }
    PnP_USB   = [ordered]@{ Allowed = ($usb.Count -gt 0);      Detail = "$($usb.Count) redirected device(s)" }
}

# ---- Output -----------------------------------------------------------------------------
Write-Host "`n== 1. Device policy (a Blocked here overrides context-based redirection) ==" -ForegroundColor Cyan
foreach ($k in $policy.Keys) {
    $c = switch ($policy[$k]) { 'Blocked' { 'Red' } 'Allowed' { 'Green' } default { 'Yellow' } }
    Write-Host ('{0,-10} {1}' -f $k, $policy[$k]) -ForegroundColor $c
}

Write-Host "`n== 2. What THIS session received ==" -ForegroundColor Cyan
foreach ($k in $session.Keys) {
    $s = $session[$k]
    $c = if ($s.Allowed) { 'Green' } else { 'Red' }
    $t = if ($s.Allowed) { 'ALLOWED' } else { 'BLOCKED' }
    Write-Host ('{0,-10} {1,-8} {2}' -f $k, $t, $s.Detail) -ForegroundColor $c
}

$blocked = @($policy.Keys | Where-Object { $policy[$_] -eq 'Blocked' })
if ($blocked.Count) {
    Write-Host "`nDevice policy blocks: $($blocked -join ', ')." -ForegroundColor Red
    Write-Host "Context-based redirection cannot allow these. Set the matching 'Do not allow ... redirection'"
    Write-Host "settings to Disabled (Intune Settings Catalog) on these Cloud PCs. New W365 Cloud PCs block all four by default."
    Write-Host "https://learn.microsoft.com/windows-365/enterprise/context-based-redirections"
}

$result = [ordered]@{
    Timestamp   = (Get-Date).ToString('o')
    Computer    = $env:COMPUTERNAME
    User        = $env:USERNAME
    SessionName = $env:SESSIONNAME
    SessionId   = $mySession
    Policy      = $policy
    Session     = $session
    PolicyBlocks = $blocked
}
$outDir = Join-Path $env:LOCALAPPDATA 'ContextRedirectionCheck'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$result | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir 'latest.json') -Encoding UTF8
Write-Host "`nJSON: $(Join-Path $outDir 'latest.json')`n"

exit ([int]($blocked.Count -gt 0))
