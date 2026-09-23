<#
.SYNOPSIS
    Enable (or disable) RDP redirections across Azure Virtual Desktop host pools and
    Windows 365 Cloud PCs, with per-change confirmation.

.DESCRIPTION
    Interactive. Authenticates with device code, then walks you through:

      1. Which platform  - AVD, Windows 365, or both.
      2. Which redirections - drive, clipboard, printer, PnP; each confirmed separately.
      3. Which scope     - all host pools, one host pool, or a provisioning policy's
                           Cloud PCs (used to identify the device set, see LIMITS).
      4. Every change is shown as BEFORE -> AFTER and requires an explicit y/n.

    WHY TWO CONTROL PLANES
    Redirection is gated in two independent places and the MOST RESTRICTIVE wins:

      a) Session host / Cloud PC OS policy  (fDisableCdm etc., set by GPO or Intune)
      b) AVD host pool RDP properties       (drivestoredirect:s:* etc.)

    Setting (b) alone does nothing if (a) is disabled - which is the common real-world
    state, because security baselines (CIS L1) set fDisableCdm = 1. This script handles
    both, and refuses to report success on (b) alone.

.LIMITS - read these, they are not bugs
    * Windows 365 provisioning policies contain NO redirection settings. The
      cloudPcProvisioningPolicy schema is image / naming / domain-join / SSO / autopatch
      only. There is no W365 equivalent of host pool RDP properties. W365 redirection is
      configured ONLY via Intune or Group Policy on the Cloud PC. This script therefore
      uses a provisioning policy solely to ENUMERATE its Cloud PCs so you know which
      devices a group needs to cover - it cannot "apply redirection to a provisioning
      policy".
    * Intune assignment targets Entra GROUPS, not arbitrary device lists. Per your
      choice, this script creates-or-reuses a named group and reports it; YOU add the
      members.
    * Two separate device-code sign-ins are required. The Azure CLI's first-party app
      does not carry DeviceManagementConfiguration.ReadWrite.All, so the Intune half
      cannot use the az token - it returns 403 naming the scope. AVD/ARM uses az;
      Intune/Graph uses Connect-MgGraph.
    * Changing the OS policy requires the session host / Cloud PC to RESTART before it
      takes effect. The script says so; it does not reboot anything.

.PARAMETER SubscriptionId
    Optional. Limit AVD host pool discovery to one subscription. Default: all
    subscriptions the signed-in account can see.

.PARAMETER GroupName
    Name of the Entra group to create or reuse for the Intune assignment.
    Default: 'AVD-W365-Redirection-Enabled'

.PARAMETER Disable
    Invert the whole run: block the selected redirections instead of enabling them.

.PARAMETER DryRun
    Show every change that WOULD be made and exit. No prompts, no writes.

.PARAMETER LogPath
    Transcript of decisions and results. Default C:\ProgramData\AvdRedirection\apply-<stamp>.json

.EXAMPLE
    .\Set-AvdW365Redirection.ps1

.EXAMPLE
    .\Set-AvdW365Redirection.ps1 -DryRun

.EXAMPLE
    .\Set-AvdW365Redirection.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

.NOTES
    Requires: Azure CLI, and the Microsoft.Graph.Authentication PowerShell module for the
    Intune half. Provided AS IS. Run it against a pilot host pool first.
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId,
    [string] $GroupName = 'AVD-W365-Redirection-Enabled',
    [switch] $Disable,
    [switch] $DryRun,
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $LogPath) {
    $LogPath = Join-Path 'C:\ProgramData\AvdRedirection' ("apply-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$script:Actions = New-Object System.Collections.Generic.List[object]
$script:Verb    = if ($Disable) { 'DISABLE' } else { 'ENABLE' }

# --------------------------------------------------------------------- helpers
function Write-Head { param([string]$t) Write-Host ""; Write-Host ("=" * 70) -ForegroundColor DarkCyan; Write-Host " $t" -ForegroundColor Cyan; Write-Host ("=" * 70) -ForegroundColor DarkCyan }
function Write-Step { param([string]$t) Write-Host ""; Write-Host "--- $t" -ForegroundColor Cyan }
function Write-Ok   { param([string]$t) Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Write-Warn { param([string]$t) Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Write-Err  { param([string]$t) Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Write-Note { param([string]$t) Write-Host "         $t" -ForegroundColor DarkGray }

function Confirm-Change {
    <#  Shows BEFORE -> AFTER and requires an explicit y. Records the decision. #>
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Setting,
        [string] $Before,
        [string] $After
    )
    Write-Host ""
    Write-Host "  CHANGE  $Target" -ForegroundColor White
    Write-Host "  Setting $Setting" -ForegroundColor White
    Write-Host "  BEFORE  $(if ([string]::IsNullOrWhiteSpace($Before)) { '<not set>' } else { $Before })" -ForegroundColor DarkYellow
    Write-Host "  AFTER   $After" -ForegroundColor Green

    if ($DryRun) {
        Write-Host "  [DRY RUN] not applied" -ForegroundColor Magenta
        $script:Actions.Add([pscustomobject]@{ Target=$Target; Setting=$Setting; Before=$Before; After=$After; Decision='dry-run'; Result='skipped' })
        return $false
    }
    $ans = Read-Host "  Apply this change? [y/N]"
    $yes = $ans -match '^(y|yes)$'
    if (-not $yes) {
        Write-Host "  skipped" -ForegroundColor DarkGray
        $script:Actions.Add([pscustomobject]@{ Target=$Target; Setting=$Setting; Before=$Before; After=$After; Decision='declined'; Result='skipped' })
    }
    return $yes
}

function Write-ActionResult {
    param([string]$Target, [string]$Setting, [string]$Before, [string]$After, [string]$Result, [string]$Detail)
    $script:Actions.Add([pscustomobject]@{ Target=$Target; Setting=$Setting; Before=$Before; After=$After; Decision='approved'; Result=$Result; Detail=$Detail })
}

function Read-Choice {
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string[]]$Options)
    while ($true) {
        Write-Host ""
        Write-Host "  $Prompt" -ForegroundColor White
        for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "    $($i+1). $($Options[$i])" }
        $sel = Read-Host "  Choice [1-$($Options.Count)]"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $Options.Count) { return [int]$sel }
        Write-Warn 'Invalid selection.'
    }
}

function Invoke-Az {
    <#  az CLI wrapper that surfaces stderr instead of swallowing it. #>
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$Raw)
    $out = & az @AzArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "az $($AzArgs -join ' ') failed ($code): $($out | Out-String)" }
    if ($Raw) { return ($out | Out-String) }
    $text = ($out | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

# ---------------------------------------------------------- redirection catalog
# Each entry ties together the three representations of one redirection:
#   RegValue  - the OS policy value name (what the diagnostic script reports)
#   Csp       - Policy CSP / settings-catalog setting id (verified at runtime)
#   RdpProp   - the AVD host pool RDP property, if one exists
# NOTE the OS policy values are inverted ("DoNotAllow..."): to ENABLE a redirection the
# policy must be set to Disabled/0. Getting this backwards is the classic own-goal.
$RedirectionCatalog = @(
    [pscustomobject]@{
        Key='Drive'; Label='Drive / storage redirection'
        RegValue='fDisableCdm'
        Csp='device_vendor_msft_policy_config_remotedesktopservices_donotallowdriveredirection'
        RdpProp='drivestoredirect'; RdpEnable='*'; RdpDisable=''
        Doc='https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage'
    }
    [pscustomobject]@{
        Key='Clipboard'; Label='Clipboard redirection'
        RegValue='fDisableClip'
        Csp='device_vendor_msft_policy_config_remotedesktopservices_donotallowclipboardredirection'
        RdpProp='redirectclipboard'; RdpEnable='1'; RdpDisable='0'
        Doc='https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-clipboard'
    }
    [pscustomobject]@{
        Key='Printer'; Label='Printer redirection'
        RegValue='fDisableCpm'
        Csp='device_vendor_msft_policy_config_remotedesktopservices_donotallowclientprinterredirection'
        RdpProp='redirectprinters'; RdpEnable='1'; RdpDisable='0'
        Doc='https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-printers'
    }
    [pscustomobject]@{
        Key='PnP'; Label='PnP / supported device redirection'
        RegValue='fDisablePNPRedir'
        Csp='device_vendor_msft_policy_config_remotedesktopservices_donotallowsupporteddeviceredirection'
        RdpProp=$null; RdpEnable=$null; RdpDisable=$null
        Doc='https://learn.microsoft.com/azure/virtual-desktop/redirection-remote-desktop-protocol'
    }
)

# ------------------------------------------------------------------ RDP parsing
function ConvertFrom-RdpPropertyString {
    <#  "a:i:1;b:s:x" -> ordered hashtable of name => @{Type;Value}.
        Split is deliberate: a drive list (drivestoredirect:s:C:\;D:\) also uses ';',
        so any token that does not match name:t:value is appended to the previous
        value rather than silently dropped.  #>
    param([string]$Text)
    $map = [ordered]@{}
    $last = $null
    if ([string]::IsNullOrWhiteSpace($Text)) { return $map }
    foreach ($tok in ($Text -split ';')) {
        if ($tok -match '^\s*([a-zA-Z0-9\s\*]+):([sib]):(.*)$') {
            $name = $Matches[1].Trim().ToLower()
            $map[$name] = [pscustomobject]@{ Type = $Matches[2]; Value = $Matches[3] }
            $last = $name
        } elseif ($last -and $tok -ne '') {
            $map[$last].Value = "$($map[$last].Value);$tok"
        }
    }
    return $map
}

function ConvertTo-RdpPropertyString {
    param($Map)
    return (($Map.Keys | ForEach-Object { "$_`:$($Map[$_].Type):$($Map[$_].Value)" }) -join ';')
}

# ============================================================== AUTH: ARM (az)
function Connect-Arm {
    Write-Step 'Azure CLI sign-in (ARM / AVD)'
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI not found. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli'
    }
    $acct = $null
    try { $acct = Invoke-Az @('account','show','-o','json') } catch { $acct = $null }
    if (-not $acct) {
        Write-Note 'No cached Azure CLI session. Starting device code sign-in.'
        Write-Host ""
        Write-Host '  A code and URL will appear below. Open the URL and enter the code.' -ForegroundColor Yellow
        Write-Host '  The code expires in about 15 minutes.' -ForegroundColor Yellow
        & az login --use-device-code --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
        $acct = Invoke-Az @('account','show','-o','json')
    }
    Write-Ok "Signed in as $($acct.user.name)  tenant $($acct.tenantId)"
    return $acct
}

# =========================================================== AUTH: Graph (Intune)
function Connect-GraphIntune {
    Write-Step 'Microsoft Graph sign-in (Intune / Windows 365)'
    Write-Note 'Separate sign-in required: the Azure CLI app does not hold'
    Write-Note 'DeviceManagementConfiguration.ReadWrite.All, so its token returns 403 here.'
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication module not found. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = $null
    try { $ctx = Get-MgContext } catch { $ctx = $null }
    $need = @('DeviceManagementConfiguration.ReadWrite.All','Group.ReadWrite.All','CloudPC.Read.All')
    $have = if ($ctx) { @($ctx.Scopes) } else { @() }
    $missing = @($need | Where-Object { $_ -notin $have })

    if (-not $ctx -or $missing.Count -gt 0) {
        Write-Host ""
        Write-Host '  A second device code will appear. Open the URL and enter the code.' -ForegroundColor Yellow
        Write-Host '  Device codes expire after ~120 seconds of inactivity - be at the keyboard.' -ForegroundColor Yellow
        Read-Host '  Press Enter when you are ready to receive the code'
        Connect-MgGraph -Scopes $need -UseDeviceAuthentication -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext
    }
    Write-Ok "Graph connected as $($ctx.Account)  tenant $($ctx.TenantId)"
    return $ctx
}

# ==================================================================== AVD half
function Get-AvdHostPool {
    param([string]$SubId)
    $subs = @()
    if ($SubId) {
        $subs = @(Invoke-Az @('account','show','--subscription',$SubId,'-o','json'))
    } else {
        $subs = @(Invoke-Az @('account','list','--query','[?state==`Enabled`]','-o','json'))
    }
    $pools = @()
    foreach ($s in $subs) {
        Write-Note "scanning subscription $($s.name)"
        $uri = "/subscriptions/$($s.id)/providers/Microsoft.DesktopVirtualization/hostPools?api-version=2024-04-03"
        try {
            $resp = Invoke-Az @('rest','--method','get','--url',"https://management.azure.com$uri",'-o','json')
            foreach ($p in @($resp.value)) {
                $pools += [pscustomobject]@{
                    Name           = $p.name
                    Id             = $p.id
                    Subscription   = $s.name
                    SubscriptionId = $s.id
                    HostPoolType   = $p.properties.hostPoolType
                    PreferredApp   = $p.properties.preferredAppGroupType
                    CustomRdp      = $(if ($p.properties.PSObject.Properties.Name -contains 'customRdpProperty') { [string]$p.properties.customRdpProperty } else { '' })
                }
            }
        } catch {
            Write-Warn "could not list host pools in $($s.name): $($_.Exception.Message)"
        }
    }
    return $pools
}

function Set-HostPoolRedirection {
    # Gating is Confirm-Change + -DryRun, not ShouldProcess - see note on
    # Set-IntuneRedirectionPolicy.
    param([Parameter(Mandatory)]$Pool, [Parameter(Mandatory)][object[]]$Redirections)

    $map = ConvertFrom-RdpPropertyString -Text $Pool.CustomRdp
    $before = $Pool.CustomRdp
    $changed = $false

    foreach ($r in $Redirections) {
        if (-not $r.RdpProp) {
            Write-Note "$($r.Label): no host pool RDP property exists - OS policy only."
            continue
        }
        $target = if ($Disable) { $r.RdpDisable } else { $r.RdpEnable }
        $type   = if ($r.RdpProp -eq 'drivestoredirect') { 's' } else { 'i' }
        $cur    = if ($map.Contains($r.RdpProp)) { $map[$r.RdpProp].Value } else { $null }

        if ($null -ne $cur -and $cur -eq $target) {
            Write-Ok "$($Pool.Name): $($r.RdpProp) already $target"
            continue
        }
        $projected = @{}
        foreach ($k in $map.Keys) { $projected[$k] = $map[$k] }
        $projected[$r.RdpProp] = [pscustomobject]@{ Type = $type; Value = $target }

        $ok = Confirm-Change -Target "AVD host pool '$($Pool.Name)' ($($Pool.Subscription))" `
                             -Setting "RDP property $($r.RdpProp)" `
                             -Before  $(if ($null -eq $cur) { '<not set>' } else { "$($r.RdpProp):$type`:$cur" }) `
                             -After   "$($r.RdpProp):$type`:$target"
        if ($ok) {
            $map[$r.RdpProp] = [pscustomobject]@{ Type = $type; Value = $target }
            $changed = $true
        }
    }

    if (-not $changed) { return }

    $new = ConvertTo-RdpPropertyString -Map $map
    $body = @{ properties = @{ customRdpProperty = $new } } | ConvertTo-Json -Depth 5 -Compress
    $tmp  = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8
        $url = "https://management.azure.com$($Pool.Id)?api-version=2024-04-03"
        Invoke-Az @('rest','--method','patch','--url',$url,'--headers','Content-Type=application/json','--body',"@$tmp",'-o','json') | Out-Null

        # Read back from the API - do not trust the write's own exit code.
        $after = Invoke-Az @('rest','--method','get','--url',$url,'-o','json')
        $actual = [string]$after.properties.customRdpProperty
        if ($actual -eq $new) {
            Write-Ok "$($Pool.Name): customRdpProperty verified = $actual"
            Write-ActionResult -Target "AVD host pool '$($Pool.Name)'" -Setting 'customRdpProperty' -Before $before -After $actual -Result 'applied' -Detail 'verified by read-back'
        } else {
            Write-Err "$($Pool.Name): read-back MISMATCH. wanted '$new' got '$actual'"
            Write-ActionResult -Target "AVD host pool '$($Pool.Name)'" -Setting 'customRdpProperty' -Before $before -After $new -Result 'mismatch' -Detail "read-back returned '$actual'"
        }
    } catch {
        Write-Err "$($Pool.Name): PATCH failed - $($_.Exception.Message)"
        Write-ActionResult -Target "AVD host pool '$($Pool.Name)'" -Setting 'customRdpProperty' -Before $before -After $new -Result 'failed' -Detail $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ================================================================= Intune half
function Resolve-SettingDefinition {
    <#  Verify a settings-catalog id against the live catalog. Guessed ids read
        plausible and fail at policy-create time with an opaque error, so prove each
        one exists first and surface the real choice option ids.  #>
    param([Parameter(Mandatory)][string]$SettingId)
    $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationSettings('$SettingId')"
    try {
        $d = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        return $d
    } catch {
        return $null
    }
}

function Get-ChoiceOptionId {
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][bool]$WantEnabledPolicy)
    # ADMX-backed "Do not allow X" settings are choice settings with options whose
    # itemId ends in _0 (Disabled) and _1 (Enabled). WantEnabledPolicy=$true means we
    # want the POLICY enabled, i.e. the redirection BLOCKED.
    $opts = @()
    if ($Definition.PSObject.Properties.Name -contains 'options') { $opts = @($Definition.options) }
    if (-not $opts) { return $null }
    $suffix = if ($WantEnabledPolicy) { '_1' } else { '_0' }
    $hit = $opts | Where-Object { $_.itemId -like "*$suffix" } | Select-Object -First 1
    if ($hit) { return $hit.itemId }
    return $null
}

function Get-OrCreateGroup {
    param([Parameter(Mandatory)][string]$Name)
    $esc = $Name.Replace("'", "''")
    $found = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$esc'"
    if ($found.value -and @($found.value).Count -gt 0) {
        $g = @($found.value)[0]
        Write-Ok "Reusing existing group '$Name' ($($g.id))"
        return $g
    }
    if ($DryRun) {
        Write-Host "  [DRY RUN] would create Entra group '$Name'" -ForegroundColor Magenta
        return $null
    }
    $ans = Read-Host "  Entra group '$Name' does not exist. Create it? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Warn 'Declined - cannot assign the Intune policy without a group.'; return $null }

    $mailNick = ($Name -replace '[^a-zA-Z0-9]', '')
    $body = @{
        displayName     = $Name
        description     = 'Targets for AVD/Windows 365 RDP redirection policy. Membership managed manually.'
        mailEnabled     = $false
        mailNickname    = $mailNick
        securityEnabled = $true
    }
    $g = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body ($body | ConvertTo-Json -Depth 5)
    Write-Ok "Created group '$Name' ($($g.id))"
    Write-Warn 'The group is EMPTY. Add your session hosts / Cloud PCs to it or the policy applies to nothing.'
    return $g
}

function Set-IntuneRedirectionPolicy {
    # No SupportsShouldProcess: Confirm-Change is the per-change gate and -DryRun the
    # dry-run switch. A decorative ShouldProcess attribute that is never called is worse
    # than none - it implies -WhatIf works when it does not.
    param(
        [Parameter(Mandatory)][object[]]$Redirections,
        [Parameter(Mandatory)][string]$PolicyName,
        [Parameter(Mandatory)][string]$TargetGroupName
    )

    Write-Step 'Resolving settings-catalog definitions against the live catalog'
    $resolved = @()
    foreach ($r in $Redirections) {
        $def = Resolve-SettingDefinition -SettingId $r.Csp
        if (-not $def) {
            Write-Err "$($r.Label): settings-catalog id not found in this tenant's catalog:"
            Write-Note "$($r.Csp)"
            Write-Note 'Skipping. Configure this one in the portal, or report the id so it can be corrected.'
            Write-ActionResult -Target 'Intune policy' -Setting $r.Label -Before '' -After '' -Result 'skipped' -Detail "settingDefinitionId not found: $($r.Csp)"
            continue
        }
        # To ENABLE a redirection, the "Do not allow..." policy must be DISABLED.
        $wantPolicyEnabled = [bool]$Disable
        $opt = Get-ChoiceOptionId -Definition $def -WantEnabledPolicy $wantPolicyEnabled
        if (-not $opt) {
            Write-Err "$($r.Label): could not determine the option itemId from the catalog definition."
            Write-ActionResult -Target 'Intune policy' -Setting $r.Label -Before '' -After '' -Result 'skipped' -Detail 'no matching choice option'
            continue
        }
        Write-Ok "$($r.Label): $($r.Csp)  ->  $opt"
        $resolved += [pscustomobject]@{ Redirection = $r; Definition = $def; OptionId = $opt }
    }

    if ($resolved.Count -eq 0) { Write-Err 'No settings resolved - nothing to create.'; return }

    Write-Step 'Per-setting confirmation'
    $approved = @()
    foreach ($x in $resolved) {
        $state = if ($Disable) { 'Enabled  (redirection BLOCKED)' } else { 'Disabled (redirection ALLOWED)' }
        $ok = Confirm-Change -Target "Intune settings-catalog policy '$PolicyName'" `
                             -Setting "$($x.Redirection.Label)  [$($x.Redirection.RegValue)]" `
                             -Before  'per existing baseline (see diagnostic output)' `
                             -After   "'Do not allow ...' = $state"
        if ($ok) { $approved += $x }
    }
    if ($approved.Count -eq 0) { Write-Warn 'No settings approved - not creating a policy.'; return }

    $group = Get-OrCreateGroup -Name $TargetGroupName
    if (-not $group) { return }

    $settings = @()
    foreach ($x in $approved) {
        $settings += @{
            '@odata.type'     = '#microsoft.graph.deviceManagementConfigurationSetting'
            settingInstance   = @{
                '@odata.type'         = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                settingDefinitionId   = $x.Redirection.Csp
                choiceSettingValue    = @{
                    '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                    value         = $x.OptionId
                    children      = @()
                }
            }
        }
    }

    $body = @{
        name         = $PolicyName
        description  = "RDP redirection - $($script:Verb) - created by Set-AvdW365Redirection.ps1 on $(Get-Date -Format s)"
        platforms    = 'windows10'
        technologies = 'mdm'
        settings     = $settings
    }

    Write-Step "Creating settings-catalog policy '$PolicyName'"
    try {
        $policy = Invoke-MgGraphRequest -Method POST `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' `
            -Body ($body | ConvertTo-Json -Depth 20)
        Write-Ok "Created policy id $($policy.id)"

        # assign - merge, never replace: a shared group usually carries other targets
        $assignBody = @{
            assignments = @(
                @{
                    target = @{
                        '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                        groupId       = $group.id
                    }
                }
            )
        }
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($policy.id)')/assign" `
            -Body ($assignBody | ConvertTo-Json -Depth 10) | Out-Null

        # read back from the API rather than trusting the POST
        $check = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($policy.id)')/assignments"
        $count = @($check.value).Count
        if ($count -gt 0) {
            Write-Ok "Assignment verified: $count target(s) on policy $($policy.id)"
            Write-ActionResult -Target "Intune policy '$PolicyName'" -Setting "$($approved.Count) setting(s)" -Before 'none' -After "assigned to $TargetGroupName" -Result 'applied' -Detail "policyId=$($policy.id); groupId=$($group.id)"
        } else {
            Write-Err 'Policy created but assignment read-back returned none.'
            Write-ActionResult -Target "Intune policy '$PolicyName'" -Setting 'assignment' -Before 'none' -After $TargetGroupName -Result 'mismatch' -Detail "policyId=$($policy.id)"
        }
    } catch {
        Write-Err "Policy create/assign failed: $($_.Exception.Message)"
        Write-ActionResult -Target "Intune policy '$PolicyName'" -Setting 'create' -Before '' -After '' -Result 'failed' -Detail $_.Exception.Message
    }
}

function Get-CloudPcsForProvisioningPolicy {
    param([Parameter(Mandatory)][string]$PolicyId)
    # Provisioning policies carry NO redirection settings - this is enumeration only,
    # so you know which devices the assignment group must cover.
    $all = @()
    $uri = 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs'
    while ($uri) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $uri
        $all += @($r.value)
        $uri = if ($r.PSObject.Properties.Name -contains '@odata.nextLink') { $r.'@odata.nextLink' } else { $null }
    }
    return @($all | Where-Object { $_.provisioningPolicyId -eq $PolicyId })
}

# ======================================================================== main
Write-Head "AVD / Windows 365 redirection - $($script:Verb)"
if ($DryRun) { Write-Host "  DRY RUN - nothing will be written." -ForegroundColor Magenta }
Write-Note 'Redirection is gated in two places and the MOST RESTRICTIVE wins:'
Write-Note '  (a) OS policy on the session host / Cloud PC  (Intune or GPO)'
Write-Note '  (b) AVD host pool RDP properties'
Write-Note 'Setting (b) alone will not help if (a) blocks it.'

$platform = Read-Choice -Prompt 'Which platform?' -Options @(
    'Azure Virtual Desktop (host pool RDP properties + Intune OS policy)',
    'Windows 365 (Intune OS policy only - no host pool exists)',
    'Both'
)

Write-Step 'Which redirections?'
Write-Note 'Each is confirmed individually later; this just picks the candidates.'
$selected = @()
foreach ($r in $RedirectionCatalog) {
    $ans = Read-Host "  Include $($r.Label)  [$($r.RegValue)]? [y/N]"
    if ($ans -match '^(y|yes)$') { $selected += $r }
}
if ($selected.Count -eq 0) { Write-Warn 'Nothing selected. Exiting.'; return }
Write-Ok "Selected: $(($selected | ForEach-Object Label) -join ', ')"

$doAvd  = $platform -in 1,3
$doW365 = $platform -in 2,3

# ---- AVD
if ($doAvd) {
    Write-Head 'Azure Virtual Desktop - host pool RDP properties'
    $null = Connect-Arm
    $pools = Get-AvdHostPool -SubId $SubscriptionId
    if (-not $pools -or $pools.Count -eq 0) {
        Write-Warn 'No AVD host pools found in scope.'
    } else {
        Write-Ok "Found $($pools.Count) host pool(s)."
        foreach ($p in $pools) {
            Write-Host "    - $($p.Name)  [$($p.HostPoolType)/$($p.PreferredApp)]  $($p.Subscription)" -ForegroundColor DarkGray
            Write-Host "      current: $(if ($p.CustomRdp) { $p.CustomRdp } else { '<none>' })" -ForegroundColor DarkGray
        }
        $scope = Read-Choice -Prompt 'Apply to which host pools?' -Options @('All of them','Pick one','Skip the AVD half')
        $targets = @()
        if ($scope -eq 1) { $targets = $pools }
        elseif ($scope -eq 2) {
            $names = @($pools | ForEach-Object { "$($_.Name)  ($($_.Subscription))" })
            $i = Read-Choice -Prompt 'Which host pool?' -Options $names
            $targets = @($pools[$i-1])
        }
        foreach ($t in $targets) { Set-HostPoolRedirection -Pool $t -Redirections $selected }
    }
}

# ---- Windows 365 / Intune
if ($doW365 -or $doAvd) {
    Write-Head 'Intune - OS policy (applies to AVD session hosts AND Cloud PCs)'
    Write-Note 'This is the half that actually unblocks fDisableCdm-style baseline settings.'
    $ansI = Read-Host '  Configure the Intune OS policy now? [y/N]'
    if ($ansI -match '^(y|yes)$') {
        $null = Connect-GraphIntune

        if ($doW365) {
            $ansP = Read-Host '  List Cloud PCs by provisioning policy, to size the assignment group? [y/N]'
            if ($ansP -match '^(y|yes)$') {
                try {
                    $pp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/provisioningPolicies'
                    $list = @($pp.value)
                    if ($list.Count -eq 0) { Write-Warn 'No provisioning policies found.' }
                    else {
                        $i = Read-Choice -Prompt 'Which provisioning policy?' -Options @($list | ForEach-Object { $_.displayName })
                        $sel = $list[$i-1]
                        $pcs = Get-CloudPcsForProvisioningPolicy -PolicyId $sel.id
                        Write-Ok "Provisioning policy '$($sel.displayName)' has $($pcs.Count) Cloud PC(s)."
                        Write-Warn 'Provisioning policies hold NO redirection settings - this list is informational.'
                        Write-Note 'Ensure your assignment group covers these devices (or their users).'
                        foreach ($pc in ($pcs | Select-Object -First 25)) {
                            Write-Host "      $($pc.displayName)  $($pc.status)" -ForegroundColor DarkGray
                        }
                        if ($pcs.Count -gt 25) { Write-Note "... and $($pcs.Count - 25) more" }
                    }
                } catch { Write-Warn "Could not enumerate provisioning policies: $($_.Exception.Message)" }
            }
        }

        $policyName = "RDP Redirection - $($script:Verb) - $(Get-Date -Format 'yyyy-MM-dd')"
        Set-IntuneRedirectionPolicy -Redirections $selected -PolicyName $policyName -TargetGroupName $GroupName
    } else {
        Write-Warn 'Intune half skipped.'
        Write-Warn 'If a baseline sets fDisableCdm = 1, the host pool change alone will NOT enable drives.'
    }
}

# ---- report
Write-Head 'Summary'
if ($script:Actions.Count -eq 0) {
    Write-Warn 'No changes recorded.'
} else {
    foreach ($a in $script:Actions) {
        $c = switch ($a.Result) { 'applied' { 'Green' } 'failed' { 'Red' } 'mismatch' { 'Red' } default { 'DarkGray' } }
        Write-Host ("  [{0,-8}] {1} :: {2}" -f $a.Result, $a.Target, $a.Setting) -ForegroundColor $c
    }
}

$dir = Split-Path -Parent $LogPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
@{
    GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Mode         = $script:Verb
    DryRun       = [bool]$DryRun
    Selected     = @($selected | ForEach-Object Key)
    Actions      = @($script:Actions)
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LogPath -Encoding UTF8

Write-Host ""
Write-Host "Record: $LogPath" -ForegroundColor White
Write-Host ""
Write-Warn 'NOT DONE YET: OS policy changes need the session host / Cloud PC to RESTART.'
Write-Note 'Then re-run Test-AvdDriveRedirection.ps1 on a host to confirm fDisableCdm is gone.'
foreach ($r in $selected) { Write-Note "$($r.Label): $($r.Doc)" }

$failed = @($script:Actions | Where-Object { $_.Result -in 'failed','mismatch' }).Count
if ($failed -gt 0) { exit 1 } else { exit 0 }
