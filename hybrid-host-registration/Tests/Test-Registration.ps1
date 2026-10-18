$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Register-AvdHybridHost.ps1'
$arguments = @{
    ComputerName = 'host01.example.test'
    Transport = 'WinRM'
    SubscriptionId = '00000000-0000-0000-0000-000000000001'
    HostPoolResourceGroup = 'pool-rg'
    HostPoolName = 'pool'
    ArcResourceGroup = 'arc-rg'
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Command {
    param($FilePath)
    if ($FilePath -eq $global:onboardingPath) { $global:arcConnected=$true; $global:agentInstalled=$true; return }
    return [pscustomobject]@{ ComputerName='HOST01'; Fqdn='host01.example.test'; DomainJoined=$true; ArcAgentInstalled=$global:agentInstalled }
}
function Get-AzContext { return [pscustomobject]@{ Subscription=[pscustomobject]@{ Id=$arguments.SubscriptionId } } }
function Get-AzWvdHostPool { return [pscustomobject]@{ Name='pool'; IdentityPrincipalId='principal-id' } }
function Get-AzRoleAssignment { return [pscustomobject]@{ RoleDefinitionName='Reader'; Scope="/subscriptions/$($arguments.SubscriptionId)/resourceGroups/arc-rg" } }
function Get-AzConnectedMachine { if ($global:arcConnected) { return [pscustomobject]@{ Name='HOST01'; Location='westus2'; Status='Connected' } } }
function Get-AzConnectedMachineExtension { return $null }
function New-PSSession { $global:sessionCalls++; return [pscustomobject]@{ Id=1 } }
function Remove-PSSession { $global:sessionCloses++ }
function Connect-AzConnectedMachine {
    param($Name, $ResourceGroupName, $Location, $SubscriptionId, $PSSession)
    $global:arcConnectCalls++
    if ($global:failArcConnect) { throw 'simulated Arc failure' }
    Assert-True ($Name -eq 'HOST01' -and $ResourceGroupName -eq 'arc-rg' -and $Location -eq 'westus2' -and $SubscriptionId -eq [string]$arguments.SubscriptionId -and $PSSession.Id -eq 1) 'Arc cmdlet received wrong target or session'
    $global:arcConnected=$true; $global:agentInstalled=$true
}
function Get-AzWvdSessionHost { if ($global:hostAvailable) { return [pscustomobject]@{ Name='pool/host01.example.test'; Status='Available' } } return @() }
function New-AzWvdRegistrationInfo { $global:tokenCalls++; return [pscustomobject]@{ Token='secret-token' } }
function New-AzConnectedMachineExtension {
    param($Name, $MachineName, $ResourceGroupName, $Location, $Publisher, $ExtensionType, $ProtectedSetting)
    $global:extensionCalls++
    Assert-True ($Name -eq 'Microsoft.AzureVirtualDesktop.CloudDeviceExtension' -and $ProtectedSetting.registrationToken -eq 'secret-token') 'Extension name or protected token incorrect'
    $global:hostAvailable = $true
    return [pscustomobject]@{ Name=$Name }
}
$global:tokenCalls=0; $global:extensionCalls=0; $global:sessionCalls=0; $global:sessionCloses=0; $global:arcConnectCalls=0
$global:arcConnected=$false; $global:hostAvailable=$false; $global:agentInstalled=$true
try {
    & $scriptPath @arguments -Confirm:$false | Out-Null
    throw 'Expected missing ArcLocation error'
} catch {
    Assert-True ($_.Exception.Message -match 'ArcLocation') "Wrong error: $_"
}
Assert-True ($global:arcConnectCalls -eq 0 -and $global:extensionCalls -eq 0) 'Missing ArcLocation wrote Azure resources'
Write-Host 'PASS: missing ArcLocation fails before writes'

& $scriptPath @arguments -ArcLocation 'westus2' -WhatIf 2>$null | Out-Null
Assert-True ($global:arcConnectCalls -eq 0 -and $global:sessionCalls -eq 0) 'WhatIf connected Arc'
Write-Host 'PASS: WhatIf does not Arc-onboard'

$global:agentInstalled=$false
$global:hostAvailable=$false
$native = & $scriptPath @arguments -ArcLocation 'westus2' -Confirm:$false
Assert-True ($native.Status -eq 'Available' -and $global:agentInstalled -and $global:arcConnected) 'Native Arc onboarding did not finish'
Assert-True ($global:arcConnectCalls -eq 1 -and $global:sessionCalls -eq 1 -and $global:sessionCloses -eq 1) 'Native Arc session not used/closed exactly once'
Assert-True ($global:extensionCalls -eq 1) 'AVD registration did not follow Arc onboarding'
Write-Host 'PASS: native Arc onboarding and AVD registration via PSSession'

$global:arcConnected=$false; $global:agentInstalled=$false; $global:hostAvailable=$false; $global:failArcConnect=$true
try {
    & $scriptPath @arguments -ArcLocation 'westus2' -Confirm:$false | Out-Null
    throw 'Expected simulated Arc failure'
} catch {
    Assert-True ($_.Exception.Message -match 'simulated Arc failure') "Wrong error: $_"
}
Assert-True ($global:sessionCloses -eq 2 -and $global:extensionCalls -eq 1) 'Failed Arc onboarding leaked a session or registered AVD'
$global:failArcConnect=$false
Write-Host 'PASS: failed Arc onboarding closes session and stops before AVD'

$global:tokenCalls=0; $global:extensionCalls=0
$global:arcConnected=$false; $global:hostAvailable=$false; $global:agentInstalled=$true
try {
    & $scriptPath @arguments -WhatIf 2>$null | Out-Null
    throw 'Expected missing-Arc error'
} catch {
    Assert-True ($_.Exception.Message -match 'ArcLocation') "Wrong error: $_"
}
Assert-True ($global:tokenCalls -eq 0 -and $global:extensionCalls -eq 0) 'Missing Arc wrote Azure resources'
Write-Host 'PASS: missing Arc fails closed'

$global:arcConnected=$true; $global:agentInstalled=$false
try {
    & $scriptPath @arguments -Confirm:$false | Out-Null
    throw 'Expected absent-agent error'
} catch {
    Assert-True ($_.Exception.Message -match 'agent') "Wrong error: $_"
}
Assert-True ($global:extensionCalls -eq 0) 'Stale Arc identity registered an unrelated machine'
$global:agentInstalled=$true
Write-Host 'PASS: stale Arc record cannot register host without agent'

$global:arcConnected=$true
& $scriptPath @arguments -WhatIf 2>$null | Out-Null
Assert-True ($global:tokenCalls -eq 0 -and $global:extensionCalls -eq 0) 'WhatIf wrote Azure resources'
Write-Host 'PASS: WhatIf makes no registration writes'

$global:hostAvailable=$true
$result = & $scriptPath @arguments -Confirm:$false
Assert-True ($result.Status -eq 'Available' -and -not $result.Changed) 'Already available host did not return unchanged'
Assert-True ($global:tokenCalls -eq 0 -and $global:extensionCalls -eq 0) 'Already available host wrote Azure resources'
Write-Host 'PASS: available host is idempotent'

$global:hostAvailable=$false
$registered = & $scriptPath @arguments -Confirm:$false
Assert-True ($registered.Status -eq 'Available' -and $registered.Changed) 'New registration did not verify host-pool availability'
Assert-True ($global:tokenCalls -eq 1 -and $global:extensionCalls -eq 1) 'Registration must create one fresh token and one extension'
Write-Host 'PASS: registration uses protected token and verifies host pool'

$global:arcConnected=$false; $global:agentInstalled=$false; $global:hostAvailable=$false
$global:onboardingPath=$PSCommandPath
$onboarded = & $scriptPath @arguments -ArcOnboardingScriptPath $global:onboardingPath -Confirm:$false
Assert-True ($onboarded.Status -eq 'Available' -and $global:agentInstalled -and $global:arcConnected) 'Onboarding and registration did not finish'
Assert-True ($global:tokenCalls -eq 2 -and $global:extensionCalls -eq 2) 'Onboarding did not register exactly once'
Write-Host 'PASS: operator-supplied Arc onboarding precedes registration'

$global:hostAvailable=$false
function Get-AzRoleAssignment { return @() }
try {
    & $scriptPath @arguments -Confirm:$false | Out-Null
    throw 'Expected Reader failure'
} catch {
    Assert-True ($_.Exception.Message -match 'Reader') "Wrong error: $_"
}
Assert-True ($global:tokenCalls -eq 2 -and $global:extensionCalls -eq 2) 'Missing Reader wrote Azure resources'
Write-Host 'PASS: missing host-pool identity access fails closed'
