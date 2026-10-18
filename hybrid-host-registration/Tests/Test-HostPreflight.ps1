$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$scriptPath=Join-Path $root 'Test-AvdHybridHost.ps1'
$oldOS=$env:OS; $oldName=$env:COMPUTERNAME; $oldPF=$env:ProgramFiles
try {
    $env:OS='Windows_NT'; $env:COMPUTERNAME='HOST01'; $env:ProgramFiles=$PSScriptRoot
    function Get-CimInstance { [pscustomobject]@{ PartOfDomain=$true; Domain='example.test' } }
    $report = & $scriptPath
    if ($report.ComputerName -ne 'HOST01' -or $report.Fqdn -ne 'HOST01.example.test' -or -not $report.DomainJoined) { throw 'Host identity probe failed' }
    if ($report.ArcAgentInstalled) { throw 'Arc agent absent should report false' }
    Write-Host 'PASS: read-only host preflight reports identity and Arc agent absence'
} finally { $env:OS=$oldOS; $env:COMPUTERNAME=$oldName; $env:ProgramFiles=$oldPF }
