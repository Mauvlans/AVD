#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [ValidateSet('WinRM','SSH')][string]$Transport = 'WinRM',
    [string]$SSHUserName,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][string]$HostPoolResourceGroup,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$ArcResourceGroup,
    [string]$ArcOnboardingScriptPath,
    [ValidateRange(1,60)][int]$TimeoutMinutes = 25
)
$ErrorActionPreference = 'Stop'
if ($Transport -eq 'SSH' -and -not $SSHUserName) { throw 'SSHUserName is required for SSH transport.' }
if ($ArcOnboardingScriptPath -and -not (Test-Path -LiteralPath $ArcOnboardingScriptPath -PathType Leaf)) { throw 'Arc onboarding script not found.' }

# Invoke-Command sends the local probe file over an encrypted PowerShell remoting channel.
# The SSH target must have the PowerShell subsystem configured, not only sshd.
$remote = @{ ErrorAction = 'Stop' }
if ($Transport -eq 'SSH') { $remote.HostName = $ComputerName; $remote.UserName = $SSHUserName }
else { $remote.ComputerName = $ComputerName }
$guest = Invoke-Command @remote -FilePath (Join-Path $PSScriptRoot 'Test-AvdHybridHost.ps1')
if (@($guest).Count -ne 1 -or -not $guest.ComputerName -or -not $guest.Fqdn) { throw 'Remote host did not return one valid identity. Registration stopped.' }
if (-not $guest.DomainJoined) { throw 'Remote host is not AD domain joined. This v1 flow requires AD join; registration stopped.' }
if ($guest.Fqdn -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+$') { throw 'Remote host FQDN is invalid; registration stopped.' }

foreach ($command in 'Get-AzContext','Get-AzWvdHostPool','Get-AzWvdSessionHost','Get-AzConnectedMachine','Get-AzConnectedMachineExtension','Get-AzRoleAssignment','New-AzWvdRegistrationInfo','New-AzConnectedMachineExtension') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing Azure PowerShell command $command. Install Az.Accounts, Az.Resources, Az.DesktopVirtualization, and Az.ConnectedMachine on the operator machine." }
}
$context = Get-AzContext
if (-not $context -or [string]$context.Subscription.Id -ne [string]$SubscriptionId) { throw 'Azure PowerShell context does not match SubscriptionId; set the context explicitly before running.' }
$pool = Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $HostPoolResourceGroup
if (-not $pool) { throw 'Host pool not found.' }
if (-not $pool.IdentityPrincipalId) { throw 'Host pool has no managed identity principal ID. Assign a managed identity first.' }
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup"
$roles = @(Get-AzRoleAssignment -ObjectId $pool.IdentityPrincipalId)
$access = @($roles | Where-Object {
    $_.RoleDefinitionName -in @('Reader','Contributor','Owner') -and
    ($_.Scope -ieq $scope -or $_.Scope -ieq "/subscriptions/$SubscriptionId")
})
if (-not $access) { throw "Host pool identity lacks a verified Reader/Contributor/Owner assignment on $scope or its subscription. Grant Reader on the Arc resource group first (custom/inherited management-group roles require manual review)." }

$machine = Get-AzConnectedMachine -Name $guest.ComputerName -ResourceGroupName $ArcResourceGroup -ErrorAction SilentlyContinue
if ($machine -and -not $guest.ArcAgentInstalled) { throw 'Arc agent is absent on the guest even though Azure has a matching machine record; refusing to act on a potentially stale Arc identity.' }
if (-not $machine -or $machine.Status -ne 'Connected') {
    if (-not $ArcOnboardingScriptPath) { throw 'Arc machine is not Connected. Supply a reviewed Arc onboarding script with -ArcOnboardingScriptPath or onboard the host separately; registration stopped.' }
    if (-not $PSCmdlet.ShouldProcess($ComputerName, 'Run operator-supplied Arc onboarding script over remoting')) { return }
    # Never print the onboarding script, its output, or secrets to the console.
    Invoke-Command @remote -FilePath $ArcOnboardingScriptPath | Out-Null
    $guest = Invoke-Command @remote -FilePath (Join-Path $PSScriptRoot 'Test-AvdHybridHost.ps1')
    if (-not $guest.ArcAgentInstalled) { throw 'Arc onboarding returned but the agent is absent on the guest.' }
    $machine = Get-AzConnectedMachine -Name $guest.ComputerName -ResourceGroupName $ArcResourceGroup
    if (-not $machine -or $machine.Status -ne 'Connected') { throw 'Arc onboarding returned, but the Arc machine is not Connected in Azure.' }
}
if ($machine.Name -ine $guest.ComputerName) { throw 'Arc machine identity does not match the remote host.' }
$hosts = @(Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName)
$matching = @($hosts | Where-Object { ($_.Name -split '/')[-1] -ieq $guest.Fqdn })
if ($matching.Count -gt 1) { throw 'Multiple session hosts match the guest FQDN; registration stopped.' }
if ($matching.Count -eq 1 -and $matching[0].Status -eq 'Available') {
    [pscustomobject]@{ ComputerName=$guest.ComputerName; SessionHost=$guest.Fqdn; Status='Available'; Changed=$false }
    return
}
$extName = 'Microsoft.AzureVirtualDesktop.CloudDeviceExtension'
$extension = Get-AzConnectedMachineExtension -Name $extName -MachineName $machine.Name -ResourceGroupName $ArcResourceGroup -ErrorAction SilentlyContinue
if ($extension -and $extension.ProvisioningState -ne 'Succeeded') { throw "Existing AVD extension is $($extension.ProvisioningState); review it before changing anything." }
if (-not $extension) {
    if (-not $PSCmdlet.ShouldProcess($machine.Name, "Register Arc machine with AVD host pool $HostPoolName")) { return }
    $expires = (Get-Date).ToUniversalTime().AddHours(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $registration = New-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName -ExpirationTime $expires
    if (-not $registration.Token) { throw 'Registration token creation returned no token.' }
    try {
        New-AzConnectedMachineExtension -Name $extName -MachineName $machine.Name -ResourceGroupName $ArcResourceGroup -Location $machine.Location -Publisher 'Microsoft.AzureVirtualDesktop' -ExtensionType 'CloudDeviceExtension' -ProtectedSetting @{ registrationToken = $registration.Token } | Out-Null
    } finally { $registration = $null }
}
elseif ($WhatIfPreference) { Write-Warning 'WhatIf: existing extension found; skipping wait for registration.'; return }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroup -HostPoolName $HostPoolName)
    $matching = @($hosts | Where-Object { ($_.Name -split '/')[-1] -ieq $guest.Fqdn })
    if ($matching.Count -gt 1) { throw 'Multiple session hosts match the guest FQDN.' }
    if ($matching.Count -eq 1 -and $matching[0].Status -eq 'Available') {
        [pscustomobject]@{ ComputerName=$guest.ComputerName; SessionHost=$guest.Fqdn; Status='Available'; Changed=(-not [bool]$extension) }
        return
    }
    if ((Get-Date) -ge $deadline) { break }
    Start-Sleep -Seconds 20
} while ($true)
throw "Timed out waiting for $($guest.Fqdn) to become Available in host pool $HostPoolName. Inspect Arc extension and AVD host-pool health; do not assume registration succeeded."
