#Requires -Version 5.1
# Read-only guest-side preflight. Run locally or from a PowerShell remoting session.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'The target must be Windows.' }
$system=Get-CimInstance Win32_ComputerSystem
$agent=Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent/azcmagent.exe'
$fqdn=if ($system.PartOfDomain) { "$($env:COMPUTERNAME).$($system.Domain)" } else { [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName }
[pscustomobject]@{
    ComputerName=$env:COMPUTERNAME
    Fqdn=$fqdn
    DomainJoined=[bool]$system.PartOfDomain
    ArcAgentInstalled=Test-Path -LiteralPath $agent -PathType Leaf
}
