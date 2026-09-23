<#
.SYNOPSIS
    Read-only diagnostic for "drive redirection not working / RemoteApp spins" on Azure Virtual Desktop.

.DESCRIPTION
    Run this INSIDE the AVD session host (best: while the affected user is logged on),
    as an administrator. It changes nothing. It collects the places that still block
    drive redirection after the host pool GUI and GPO look correct:

      1. Effective host-pool RDP properties as the agent received them
         (registry + RDP file cache), including drivestoredirect / redirectdrives.
      2. Machine policy that blocks redirection (fDisableCdm, fDisableClip, etc.) from
         BOTH the Policies hive (GPO/Intune) and the Terminal Server hive (local).
      3. RDPDR / rdpdr driver + service state, and whether the RDPDR channel opened
         in the current session.
      4. FSLogix: container mode, Profile_Status / ProfileError, VHD attach state,
         redirections.xml, and stale Terminal Server Client keys in the loaded hive.
      5. Session type (RemoteApp vs full desktop) and RAIL/streaming indicators.
      6. Client build reported by the session, and session-host AVD agent version.

    Optionally add -HostPoolName/-ResourceGroup to pull the AUTHORITATIVE custom RDP
    properties from Azure (needs Az.DesktopVirtualization and Connect-AzAccount).

.PARAMETER UserName
    sAMAccountName / UPN prefix of the affected user. Defaults to the currently
    connected interactive user if one can be determined.

.PARAMETER HostPoolName
    Optional. Host pool to query in Azure for custom RDP properties.

.PARAMETER ResourceGroup
    Optional. Resource group of the host pool.

.PARAMETER OutputPath
    Where to write the JSON report. Default C:\ProgramData\AvdDriveCheck\latest.json

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-AvdDriveRedirection.ps1 -UserName jsmith

.NOTES
    Read-only. Exit 0 = nothing blocking found. Exit 1 = at least one blocking finding.
    Provided AS IS. It does NOT reset FSLogix profiles or edit RDP properties - it tells
    you which of the three known blockers is actually present so you fix the right one.
#>

[CmdletBinding()]
param(
    [string] $UserName,
    [string] $HostPoolName,
    [string] $ResourceGroup,
    [string] $OutputPath = 'C:\ProgramData\AvdDriveCheck\latest.json'
)

$ErrorActionPreference = 'Continue'

$script:Blocking = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Info     = [ordered]@{}

# Microsoft Learn references, keyed by finding topic. Printed next to the finding and
# emitted in the JSON so a ticket carries the fix link, not just the symptom.
$script:Docs = @{
    DriveRedirectionPolicy = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage#configure-drive-redirection-using-microsoft-intune-or-group-policy'
    PolicyCsp              = 'https://learn.microsoft.com/windows/client-management/mdm/policy-csp-remotedesktopservices#donotallowdriveredirection'
    RdpProperties          = 'https://learn.microsoft.com/azure/virtual-desktop/rdp-properties#drivestoredirect'
    CustomizeRdp           = 'https://learn.microsoft.com/azure/virtual-desktop/customize-rdp-properties'
    HostPoolDriveSetting   = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage#configure-drive-redirection-using-host-pool-rdp-properties'
    FSLogixTroubleshooting = 'https://learn.microsoft.com/fslogix/troubleshooting-events-logs-diagnostics'
    FSLogixKnownIssues     = 'https://learn.microsoft.com/fslogix/troubleshooting-known-issues'
    FSLogixCloudCache      = 'https://learn.microsoft.com/fslogix/tutorial-cloud-cache-containers'
    RemoteApp              = 'https://learn.microsoft.com/azure/virtual-desktop/publish-applications-stream-remoteapp'
    RedirectionOverview    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-remote-desktop-protocol'
}

$script:DocLinks = New-Object System.Collections.Generic.List[string]

function Resolve-Doc {
    param([string]$Key)
    if ($Key -and $script:Docs.ContainsKey($Key)) { return $script:Docs[$Key] }
    return $null
}

function Add-Blocking {
    param([string]$m, [string]$Doc)
    $u = Resolve-Doc $Doc
    $script:Blocking.Add($(if ($u) { "$m`n     Fix: $u" } else { $m }))
    Write-Host "  [BLOCK] $m" -ForegroundColor Red
    if ($u) { Write-Host "          Fix: $u" -ForegroundColor Magenta; if (-not $script:DocLinks.Contains($u)) { $script:DocLinks.Add($u) } }
}

function Add-Warning2 {
    param([string]$m, [string]$Doc)
    $u = Resolve-Doc $Doc
    $script:Warnings.Add($(if ($u) { "$m`n     Ref: $u" } else { $m }))
    Write-Host "  [WARN ] $m" -ForegroundColor Yellow
    if ($u) { Write-Host "          Ref: $u" -ForegroundColor DarkMagenta; if (-not $script:DocLinks.Contains($u)) { $script:DocLinks.Add($u) } }
}
function Add-Ok       { param([string]$m) Write-Host "  [ OK  ] $m" -ForegroundColor Green }
function Section      { param([string]$t) Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $p = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $p) { return $null }
        if ($p.PSObject.Properties.Name -notcontains $Name) { return $null }
        return $p.$Name
    } catch { return $null }
}

Write-Host "AVD drive-redirection diagnostic  (read-only)" -ForegroundColor White
Write-Host "Host: $env:COMPUTERNAME   Run: $(Get-Date -Format s)" -ForegroundColor DarkGray

# ---------------------------------------------------------------- 0. context
Section '0. Session context'

$sessions = @()
try {
    $q = & quser.exe 2>$null
    if ($q) {
        $sessions = $q | Select-Object -Skip 1 | ForEach-Object {
            $line = $_ -replace '^\s?>', ' '
            $f = ($line -split '\s{2,}').Where({ $_ -ne '' })
            [pscustomobject]@{ Raw = $_.Trim(); User = ($f[0]).Trim() }
        }
    }
} catch { }

if (-not $UserName) {
    $cand = $sessions | Where-Object { $_.User -and $_.User -ne $env:USERNAME } | Select-Object -First 1
    if ($cand) { $UserName = $cand.User }
    elseif ($sessions) { $UserName = ($sessions | Select-Object -First 1).User }
}
$script:Info.HostName    = $env:COMPUTERNAME
$script:Info.TargetUser  = $UserName
$script:Info.Sessions    = @($sessions | ForEach-Object { $_.Raw })
Write-Host "  Target user: $(if($UserName){$UserName}else{'<none detected>'})"
if (-not $UserName) { Add-Warning2 'No target user detected - user-scoped FSLogix checks will be skipped. Re-run with -UserName while the user is logged on.' }

$os = Get-CimInstance Win32_OperatingSystem
$script:Info.OS = "$($os.Caption) $($os.Version)"
Add-Ok "OS: $($script:Info.OS)"

# AVD agent version
$agentVer = $null
try {
    $agentVer = (Get-ChildItem 'C:\Program Files\Microsoft RDInfra' -Filter 'RDAgent_*' -Directory -ErrorAction Stop |
                 Sort-Object Name -Descending | Select-Object -First 1).Name
} catch { }
$script:Info.RDAgentVersion = $agentVer
if ($agentVer) { Add-Ok "AVD agent: $agentVer" } else { Add-Warning2 'Could not determine AVD agent version (RDInfra folder not found) - is this actually a session host?' }

# ------------------------------------------------- 1. effective RDP properties
Section '1. Effective RDP properties seen by this session host (blocker #1)'

# The agent stashes the host pool's RDP property string locally.
$rdpPropCandidates = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'; Name = 'CustomRdpProperty' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'; Name = 'RdpProperty' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent\Stack'; Name = 'CustomRdpProperty' }
)
$effectiveRdp = $null
foreach ($c in $rdpPropCandidates) {
    $v = Get-RegValue -Path $c.Path -Name $c.Name
    if ($v) { $effectiveRdp = [string]$v; break }
}
$script:Info.EffectiveRdpProperties = $effectiveRdp

$rdpFromAzure = $null
if ($HostPoolName -and $ResourceGroup) {
    try {
        Import-Module Az.DesktopVirtualization -ErrorAction Stop
        $hp = Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $ResourceGroup -ErrorAction Stop
        $rdpFromAzure = $hp.CustomRdpProperty
        $script:Info.HostPoolType            = $hp.HostPoolType
        $script:Info.HostPoolPreferredApp    = $hp.PreferredAppGroupType
        $script:Info.CustomRdpPropertyAzure  = $rdpFromAzure
        Add-Ok "Pulled host pool '$HostPoolName' from Azure (type=$($hp.HostPoolType), preferredAppGroupType=$($hp.PreferredAppGroupType))"
    } catch {
        Add-Warning2 "Could not query Azure host pool: $($_.Exception.Message)"
    }
}

$rdpToParse = if ($rdpFromAzure) { $rdpFromAzure } elseif ($effectiveRdp) { $effectiveRdp } else { $null }

if (-not $rdpToParse) {
    Add-Warning2 'No custom RDP property string found locally. Confirm in Azure Portal -> Host Pool -> RDP Properties -> Advanced, or re-run with -HostPoolName/-ResourceGroup.' -Doc CustomizeRdp
} else {
    Write-Host "  Raw: $rdpToParse" -ForegroundColor DarkGray
    $pairs = @{}
    foreach ($tok in ($rdpToParse -split ';')) {
        if ($tok -match '^\s*([a-zA-Z0-9\*]+):([sib]):(.*)$') { $pairs[$Matches[1].ToLower()] = $Matches[3] }
    }
    $script:Info.RdpPropertyPairs = $pairs

    # drivestoredirect is THE one that matters
    if ($pairs.ContainsKey('drivestoredirect')) {
        $v = $pairs['drivestoredirect']
        if ([string]::IsNullOrWhiteSpace($v)) {
            Add-Blocking 'drivestoredirect:s: is present and EMPTY -> all drive redirection is blocked at the host pool. This overrides the GUI "Redirect all disk drives" setting. Remove it, or set drivestoredirect:s:*' -Doc HostPoolDriveSetting
        } elseif ($v -eq '*') {
            Add-Ok 'drivestoredirect:s:* -> all drives redirected (correct).'
        } else {
            Add-Warning2 "drivestoredirect:s:$v -> only these specific drives redirect. Dynamically-connected/hot-plugged drives will NOT appear. Set to * for 'all drives including ones connected later'." -Doc RdpProperties
        }
    } else {
        Add-Ok 'No drivestoredirect override in custom RDP properties.'
    }

    foreach ($k in 'redirectdrives','redirectcomports','redirectsmartcards','redirectprinters','redirectclipboard') {
        if ($pairs.ContainsKey($k)) {
            $v = $pairs[$k]
            if ($v -eq '0') {
                if ($k -eq 'redirectdrives') { Add-Blocking "redirectdrives:i:0 present -> drive redirection explicitly disabled at the host pool. Remove it." -Doc HostPoolDriveSetting }
                else { Add-Warning2 "$($k):i:0 present. Not the drive channel itself, but RDPDR carries COM/smartcard/printer too; a disabled sibling plus a RemoteApp can stall the device-redirection negotiation. Remove unless deliberate." -Doc RdpProperties }
            } else {
                Add-Ok "$($k):i:$v"
            }
        }
    }

    if ($pairs.ContainsKey('devicestoredirect')) { Add-Warning2 "devicestoredirect:s:$($pairs['devicestoredirect']) present - review." -Doc RdpProperties }
    if ($pairs.ContainsKey('remoteapplicationmode') -and $pairs['remoteapplicationmode'] -eq '1') {
        $script:Info.RemoteAppModeInRdp = $true
        Add-Warning2 'remoteapplicationmode:i:1 -> connections are RemoteApp. See section 5.' -Doc RemoteApp
    }
}

# ------------------------------------------------------- 2. policy on the host
Section '2. Machine policy on this host (GPO / Intune / local)'

$policyMap = @{
    'fDisableCdm'          = 'Drive (client drive mapping) redirection'
    'fDisableCcm'          = 'COM port redirection'
    'fDisableLPT'          = 'LPT port redirection'
    'fDisablePNPRedir'     = 'PnP device redirection'
    'fEnableSmartCard'     = 'Smart card redirection'
    'fDisableClip'         = 'Clipboard redirection'
    'fDisableCpm'          = 'Printer redirection'
}
$hives = @(
    @{ Label = 'Policy (GPO/Intune)'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' },
    @{ Label = 'Local TS config';     Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' },
    @{ Label = 'Local TS root';       Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' }
)
$polFound = [ordered]@{}
foreach ($h in $hives) {
    foreach ($k in $policyMap.Keys) {
        $v = Get-RegValue -Path $h.Path -Name $k
        if ($null -ne $v) {
            $polFound["$($h.Label)::$k"] = $v
            if ($k -eq 'fDisableCdm' -and $v -eq 1) {
                Add-Blocking "$($h.Label): fDisableCdm = 1 -> $($policyMap[$k]) is DISABLED on this session host. This blocks drives regardless of client or host pool settings. ($($h.Path))" -Doc DriveRedirectionPolicy
            } elseif ($k -ne 'fDisableCdm' -and $v -eq 1 -and $k -like 'fDisable*') {
                Add-Warning2 "$($h.Label): $k = 1 -> $($policyMap[$k]) disabled." -Doc PolicyCsp
            } else {
                Add-Ok "$($h.Label): $k = $v"
            }
        }
    }
}
if ($polFound.Count -eq 0) { Add-Ok 'No Terminal Services redirection policy values set anywhere (clean).' }
$script:Info.RedirectionPolicy = $polFound

# ------------------------------------------------------------ 3. RDPDR channel
Section '3. RDPDR device-redirection channel'

$rdpdr = Get-Service -Name 'rdpdr' -ErrorAction SilentlyContinue
$drv   = Get-CimInstance Win32_SystemDriver -Filter "Name='rdpdr'" -ErrorAction SilentlyContinue
$script:Info.RdpdrService = if ($rdpdr) { "$($rdpdr.Status)/$($rdpdr.StartType)" } elseif ($drv) { "$($drv.State)/$($drv.StartMode)" } else { $null }

if ($drv) {
    if ($drv.State -eq 'Running') { Add-Ok "rdpdr driver: $($drv.State) (start=$($drv.StartMode))" }
    else { Add-Blocking "rdpdr driver is $($drv.State) (start=$($drv.StartMode)) -> the device-redirection channel cannot open. Expect RemoteApp to hang and no drives." -Doc RedirectionOverview }
} elseif ($rdpdr) {
    if ($rdpdr.Status -eq 'Running') { Add-Ok "rdpdr service: Running" } else { Add-Blocking "rdpdr service is $($rdpdr.Status)." }
} else {
    Add-Warning2 'rdpdr driver/service not enumerable - check manually: sc query rdpdr'
}

$umrdp = Get-Service -Name 'UmRdpService' -ErrorAction SilentlyContinue
if ($umrdp) {
    $script:Info.UmRdpService = "$($umrdp.Status)/$($umrdp.StartType)"
    if ($umrdp.Status -eq 'Running') { Add-Ok 'UmRdpService (Remote Desktop Services UserMode Port Redirector): Running' }
    else { Add-Blocking "UmRdpService is $($umrdp.Status) (start=$($umrdp.StartType)) -> drive/port redirection will not work. It must be Running/Manual-triggered." -Doc RedirectionOverview }
}

# Does a redirected-drive device actually exist right now?
$tsDisks = @()
try {
    $tsDisks = Get-CimInstance Win32_LogicalDisk -Filter "ProviderName LIKE '%tsclient%'" -ErrorAction Stop |
               Select-Object DeviceID, ProviderName
} catch { }
$script:Info.RedirectedDrivesPresent = @($tsDisks | ForEach-Object { "$($_.DeviceID) -> $($_.ProviderName)" })
if ($tsDisks) { Add-Ok "Redirected drives currently visible: $(( $tsDisks | ForEach-Object DeviceID) -join ', ')" }
else { Add-Warning2 'No \\tsclient\ drives visible on this host right now (expected if the affected user is not connected at this moment).' }

# rdpdr-related errors in the last 24h
try {
    $ev = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational','System'
        StartTime = (Get-Date).AddDays(-1)
        Level     = 1,2,3
    } -ErrorAction Stop | Where-Object { $_.Message -match 'rdpdr|redirect|device' } | Select-Object -First 15
    $script:Info.RecentRedirectionEvents = @($ev | ForEach-Object { "$($_.TimeCreated.ToString('s')) [$($_.LevelDisplayName)] $($_.ProviderName) $($_.Id): $(($_.Message -split "`n")[0])" })
    if ($ev) { Add-Warning2 "$(@($ev).Count) redirection/device-related warning+ events in the last 24h (see JSON report)." }
    else { Add-Ok 'No redirection-related errors in the last 24h.' }
} catch { Add-Warning2 "Could not read event logs: $($_.Exception.Message)" }

# -------------------------------------------------------------- 4. FSLogix
Section '4. FSLogix profile container (blocker #2)'

$fslKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$fslEnabled = Get-RegValue -Path $fslKey -Name 'Enabled'
$script:Info.FSLogixEnabled = $fslEnabled
if ($null -eq $fslEnabled) {
    Add-Warning2 'FSLogix Profiles key not found - FSLogix may not be installed on this host.' -Doc FSLogixTroubleshooting
} else {
    $vhdLoc = Get-RegValue -Path $fslKey -Name 'VHDLocations'
    $ccLoc  = Get-RegValue -Path $fslKey -Name 'CCDLocations'
    $script:Info.FSLogixVHDLocations = $vhdLoc
    $script:Info.FSLogixCloudCache   = $ccLoc
    Add-Ok "FSLogix Enabled=$fslEnabled; VHDLocations=$($vhdLoc -join ',')$(if($ccLoc){"; CloudCache=$($ccLoc -join ',')"})"
    if ($ccLoc) { Add-Warning2 'Cloud Cache is in use. Cloud Cache lengthens profile load; a slow load is a common cause of RemoteApp spinning before the RDPDR channel is usable.' -Doc FSLogixCloudCache }

    $fslSvc = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue
    if ($fslSvc) {
        $script:Info.FSLogixService = "$($fslSvc.Status)"
        if ($fslSvc.Status -ne 'Running') { Add-Blocking "FSLogix service frxsvc is $($fslSvc.Status)." } else { Add-Ok 'frxsvc Running' }
    }

    # frx version (attached-container info)
    $frx = 'C:\Program Files\FSLogix\Apps\frx.exe'
    if (Test-Path $frx) {
        try { $script:Info.FrxVersion = (& $frx version 2>&1 | Out-String).Trim() } catch { }
    }

    # Profile_Status for the target user (search every local profile, newest first)
    $statusFiles = @()
    try {
        $statusFiles = @(Get-ChildItem -Path 'C:\Users' -Filter 'Profile_Status.txt' -Recurse -Force -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending)
        if ($UserName) {
            $mine = @($statusFiles | Where-Object { $_.FullName -like "*\$UserName\*" })
            if ($mine) { $statusFiles = $mine }
        }
    } catch { }

    $statusReport = @()
    foreach ($f in $statusFiles) {
        $txt = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        $statusReport += [pscustomobject]@{ Path = $f.FullName; Modified = $f.LastWriteTime; Text = $txt }
        $bad = @('LoadTimeExceeded','MountPointError','Locked','Corrupt','Error','Failed') | Where-Object { $txt -match $_ }
        if ($bad) {
            Add-Blocking "FSLogix $($f.FullName) reports: $($bad -join ', ') -> profile container is unhealthy. Reset it (log off, delete local profile folder + the user's VHD(X), let FSLogix recreate)." -Doc FSLogixTroubleshooting
        } else {
            Add-Ok "FSLogix status file clean: $($f.FullName)"
        }
    }
    if (-not $statusFiles) { Add-Warning2 'No Profile_Status.txt found. Run this while the affected user is logged on, or check the profile share directly.' }
    $script:Info.FSLogixProfileStatus = @($statusReport | ForEach-Object { @{ Path = $_.Path; Modified = $_.Modified; Text = $_.Text } })

    # FSLogix operational log errors
    try {
        $fslEv = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-FSLogix-Apps/Operational'; StartTime=(Get-Date).AddDays(-2); Level=1,2,3 } -ErrorAction Stop |
                 Select-Object -First 20
        $script:Info.FSLogixEvents = @($fslEv | ForEach-Object { "$($_.TimeCreated.ToString('s')) [$($_.LevelDisplayName)] $($_.Id): $(($_.Message -split "`n")[0])" })
        if ($fslEv) { Add-Warning2 "$(@($fslEv).Count) FSLogix warning/error events in the last 48h (see JSON)." -Doc FSLogixKnownIssues } else { Add-Ok 'No FSLogix errors in the last 48h.' }
    } catch { Add-Warning2 'FSLogix operational log not available.' }

    # Stale Terminal Server Client keys in the loaded user hive
    if ($UserName) {
        try {
            $prof = Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$UserName*" } | Select-Object -First 1
            if ($prof -and $prof.SID) {
                $tscPath = "Registry::HKEY_USERS\$($prof.SID)\Software\Microsoft\Terminal Server Client"
                if (Test-Path $tscPath) {
                    $tsc = Get-ChildItem $tscPath -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                    $script:Info.UserTerminalServerClientKeys = @($tsc)
                    Add-Warning2 "User hive has Terminal Server Client keys ($(@($tsc).Count) subkeys). Stale entries here are a known cause of a hung RemoteApp after a profile is roamed between hosts." -Doc FSLogixTroubleshooting
                } else { Add-Ok 'No stale Terminal Server Client keys in the user hive.' }
            } else { Add-Warning2 "No loaded profile found for '$UserName' on this host." }
        } catch { }
    }
}

# ------------------------------------------------- 5. RemoteApp / session mode
Section '5. RemoteApp vs full desktop (blocker #3)'

$railProcs = Get-Process -Name 'rdpshell','rdpinit' -ErrorAction SilentlyContinue
$script:Info.RailProcesses = @($railProcs | ForEach-Object { "$($_.Name) (pid $($_.Id), session $($_.SessionId))" })
if ($railProcs | Where-Object Name -eq 'rdpshell') {
    Add-Warning2 'rdpshell.exe is running -> at least one RemoteApp (RAIL) session is active on this host. RemoteApp is where the "spinning, no drives" symptom concentrates.' -Doc RemoteApp
} elseif ($railProcs | Where-Object Name -eq 'rdpinit') {
    Add-Warning2 'rdpinit.exe running -> session starting in RemoteApp mode.'
} else {
    Add-Ok 'No RAIL/RemoteApp shell processes running right now (sessions look like full desktop).'
}

if ($script:Info.HostPoolPreferredApp) {
    if ($script:Info.HostPoolPreferredApp -eq 'RailApplications') {
        Add-Warning2 "Host pool preferredAppGroupType = RailApplications (RemoteApp). If drives work in a full desktop from the same pool, the redirection MODE is the incompatibility - set drive redirection to plain 'Enabled' (drivestoredirect:s:*) rather than a dynamic/hot-plug mode." -Doc HostPoolDriveSetting
    } else {
        Add-Ok "Host pool preferredAppGroupType = $($script:Info.HostPoolPreferredApp)"
    }
}

# ---------------------------------------------------------------- 6. client
Section '6. Connected client'

try {
    $ts = Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSClientSetting -ErrorAction SilentlyContinue
    if ($ts) {
        $script:Info.TSClientSetting = @{
            DriveRedirectionDisabled = $ts.DriveRedirection
            COMPortRedirection       = $ts.COMPortRedirection
            LPTPortRedirection       = $ts.LPTPortRedirection
            ClipboardRedirection     = $ts.ClipboardMapping
        }
        if ($ts.DriveRedirection -eq 1) { Add-Blocking 'Win32_TSClientSetting.DriveRedirection = 1 (disabled) on this host.' -Doc DriveRedirectionPolicy }
        else { Add-Ok 'Win32_TSClientSetting reports drive redirection is not disabled.' }
    }
} catch { }

try {
    $null = Get-ChildItem 'HKCU:\Volatile Environment' -ErrorAction SilentlyContinue
} catch { }
foreach ($s in $sessions) { Write-Host "  session: $($s.Raw)" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- report
Section 'Summary'

$result = [ordered]@{
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    Host          = $env:COMPUTERNAME
    TargetUser    = $UserName
    BlockingCount = $script:Blocking.Count
    WarningCount  = $script:Warnings.Count
    Blocking      = @($script:Blocking)
    Warnings      = @($script:Warnings)
    DocLinks      = @($script:DocLinks)
    Details       = $script:Info
}

$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

if ($script:Blocking.Count -gt 0) {
    Write-Host ""
    Write-Host "BLOCKING FINDINGS ($($script:Blocking.Count)):" -ForegroundColor Red
    $i = 1; foreach ($b in $script:Blocking) { Write-Host "  $i. $b" -ForegroundColor Red; $i++ }
} else {
    Write-Host "No blocking findings. Review the $($script:Warnings.Count) warning(s) above." -ForegroundColor Green
}

if ($script:DocLinks.Count -gt 0) {
    Write-Host ""
    Write-Host "MICROSOFT LEARN - resolve the findings above:" -ForegroundColor Cyan
    $i = 1; foreach ($u in $script:DocLinks) { Write-Host "  $i. $u" -ForegroundColor Magenta; $i++ }
}

Write-Host ""
Write-Host "Full report: $OutputPath" -ForegroundColor White
Write-Host "Send that JSON back for analysis." -ForegroundColor White

if ($script:Blocking.Count -gt 0) { exit 1 } else { exit 0 }