<#
    Feature validator engine: catalog loading, probes, evaluation, reporting.
    Dot-sourced by Invoke-FeatureValidator.ps1 and by the offline tests, so the tests
    exercise the real functions rather than copies.

    PowerShell 5.1 compatible: no ternary, no null-coalescing, no pipeline-chain operators.
#>

# ---------------------------------------------------------------- catalog ----

$script:ValidSeverities  = @('Fail', 'Warn', 'Info')
$script:ValidPlatforms   = @('AVD', 'W365', 'Both')
$script:ValidScopes      = @('Local', 'Cloud')
$script:ValidProbeTypes  = @('Registry', 'Service', 'File', 'Process', 'Cloud')
$script:ValidExpectOps   = @('Equal', 'NotEqual', 'In', 'NotIn', 'Exists', 'NotExists', 'MinVersion')

function Import-CheckCatalog {
    <# Loads every checks/*.psd1 file and validates each entry. Throws on a malformed catalog:
       a bad check must fail loudly at load time, never silently report Pass. #>
    param([Parameter(Mandatory)][string]$Path)

    $sources = @(foreach ($file in (Get-ChildItem -Path $Path -Filter '*.psd1' | Sort-Object Name)) {
        @{ Name = $file.Name; Data = (Import-PowerShellDataFile -Path $file.FullName) }
    })
    return Resolve-CheckCatalog -Source $sources
}

function Resolve-CheckCatalog {
    <# Validates catalog data from any source: psd1 files (repo) or the catalog embedded in the
       single-file build. Both paths go through here, so both get identical validation. #>
    param([Parameter(Mandatory)][object[]]$Source)

    $checks = New-Object System.Collections.Generic.List[object]
    $ids = @{}
    foreach ($src in $Source) {
        $data = $src.Data
        if (-not $data.ContainsKey('Checks')) { throw "$($src.Name): top-level 'Checks' key missing" }
        foreach ($c in $data.Checks) {
            $problems = Test-CheckDefinition -Check $c
            if ($problems) { throw "$($src.Name) [$($c.Id)]: $($problems -join '; ')" }
            if ($ids.ContainsKey($c.Id)) { throw "Duplicate check Id '$($c.Id)' in $($src.Name) and $($ids[$c.Id])" }
            $ids[$c.Id] = $src.Name
            $checks.Add($c)
        }
    }
    return ,$checks.ToArray()
}

function Test-CheckDefinition {
    <# Returns a list of schema problems for one check entry (empty = valid). #>
    param([Parameter(Mandatory)][hashtable]$Check)

    $p = @()
    foreach ($k in 'Id', 'Feature', 'Title', 'Platform', 'Scope', 'Probe', 'Severity', 'WhenFailed', 'DocLink') {
        if (-not $Check.ContainsKey($k) -or $null -eq $Check[$k] -or "$($Check[$k])" -eq '') { $p += "missing '$k'" }
    }
    if ($p) { return $p }

    if ($script:ValidSeverities -notcontains $Check.Severity) { $p += "Severity '$($Check.Severity)' invalid" }
    if ($script:ValidPlatforms  -notcontains $Check.Platform) { $p += "Platform '$($Check.Platform)' invalid" }
    if ($script:ValidScopes     -notcontains $Check.Scope)    { $p += "Scope '$($Check.Scope)' invalid" }
    if ($Check.Probe -isnot [hashtable] -or $script:ValidProbeTypes -notcontains $Check.Probe.Type) {
        $p += "Probe.Type invalid"
    }
    if ($Check.Scope -eq 'Cloud' -and $Check.Probe.Type -ne 'Cloud') { $p += "Cloud scope requires Probe.Type 'Cloud'" }
    if ($Check.Scope -eq 'Local') {
        if (-not $Check.ContainsKey('Expect') -or $Check.Expect -isnot [hashtable] -or $Check.Expect.Count -ne 1) {
            $p += "Local checks need exactly one Expect operator"
        } else {
            $op = @($Check.Expect.Keys)[0]
            if ($script:ValidExpectOps -notcontains $op) { $p += "Expect operator '$op' invalid" }
        }
    }
    if ($Check.DocLink -notmatch '^https://') { $p += "DocLink must be https" }
    return $p
}

# ---------------------------------------------------------------- platform ----

function Get-HostPlatform {
    <# Heuristic, documented as such in the README. Returns AVD, W365 or Unknown.
       W365: Cloud PC naming (CPC-...) or the Windows365 key that Cloud PCs carry.
       AVD:  RD Infra Agent installed and not identified as a Cloud PC. #>
    param([hashtable]$Fixture)

    if ($Fixture) {
        if ($Fixture.ContainsKey('Platform')) { return $Fixture.Platform }
        return 'Unknown'
    }
    $isCloudPc = ($env:COMPUTERNAME -like 'CPC-*') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows365')
    if ($isCloudPc) { return 'W365' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent') { return 'AVD' }
    return 'Unknown'
}

# ---------------------------------------------------------------- probes ----

function Get-ProbeKey {
    <# Stable key used to look a probe up in a test fixture. #>
    param([Parameter(Mandatory)][hashtable]$Probe)
    switch ($Probe.Type) {
        'Registry' { return "Registry|$($Probe.Path)|$($Probe.Name)" }
        'Service'  { return "Service|$($Probe.Name)" }
        'File'     { return "File|$($Probe.Path)" }
        'Process'  { return "Process|$($Probe.Name)" }
        default    { return "$($Probe.Type)|" }
    }
}

function Invoke-Probe {
    <# Returns @{ Value = <observed or $null>; Error = <string or $null> }.
       $null Value means "not present" (missing registry value, service, file, process).
       With -Fixture, no system state is touched: a key absent from the fixture = not present. #>
    param(
        [Parameter(Mandatory)][hashtable]$Probe,
        [hashtable]$Fixture
    )

    if ($Fixture) {
        $key = Get-ProbeKey -Probe $Probe
        $val = $null
        if ($Fixture.ContainsKey('Probes') -and $Fixture.Probes.ContainsKey($key)) { $val = $Fixture.Probes[$key] }
        return @{ Value = $val; Error = $null }
    }

    try {
        switch ($Probe.Type) {
            'Registry' {
                $v = $null
                if (Test-Path -Path $Probe.Path) {
                    $item = Get-ItemProperty -Path $Probe.Path -Name $Probe.Name -ErrorAction SilentlyContinue
                    if ($item) { $v = $item.($Probe.Name) }
                }
                return @{ Value = $v; Error = $null }
            }
            'Service' {
                $svc = Get-Service -Name $Probe.Name -ErrorAction SilentlyContinue
                $v = $null
                if ($svc) { $v = "$($svc.Status)" }
                return @{ Value = $v; Error = $null }
            }
            'File' {
                $v = $null
                $path = [Environment]::ExpandEnvironmentVariables($Probe.Path)
                if (Test-Path -LiteralPath $path) {
                    $fi = Get-Item -LiteralPath $path
                    $v = 'Present'
                    if ($fi.VersionInfo -and $fi.VersionInfo.FileVersionRaw) { $v = "$($fi.VersionInfo.FileVersionRaw)" }
                }
                return @{ Value = $v; Error = $null }
            }
            'Process' {
                $procs = @(Get-Process -Name $Probe.Name -ErrorAction SilentlyContinue)
                $v = $null
                if ($procs.Count) { $v = 'Running' }
                return @{ Value = $v; Error = $null }
            }
            default { return @{ Value = $null; Error = "Probe type '$($Probe.Type)' is not a local probe" } }
        }
    } catch {
        return @{ Value = $null; Error = "$($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- evaluation ----

function Test-Expectation {
    <# Pure function: does an observed value satisfy one Expect operator? #>
    param($Observed, [Parameter(Mandatory)][hashtable]$Expect)

    $op  = @($Expect.Keys)[0]
    $exp = $Expect[$op]
    switch ($op) {
        'Exists'     { return ($null -ne $Observed) }
        'NotExists'  { return ($null -eq $Observed) }
        'Equal'      { return ($null -ne $Observed -and "$Observed" -eq "$exp") }
        'NotEqual'   { return ($null -eq $Observed -or "$Observed" -ne "$exp") }
        'In'         { return ($null -ne $Observed -and (@($exp) | ForEach-Object { "$_" }) -contains "$Observed") }
        'NotIn'      { return ($null -eq $Observed -or (@($exp) | ForEach-Object { "$_" }) -notcontains "$Observed") }
        'MinVersion' {
            if ($null -eq $Observed) { return $false }
            $o = $null; $m = $null
            if (-not [version]::TryParse("$Observed", [ref]$o)) { return $false }
            if (-not [version]::TryParse("$exp", [ref]$m)) { return $false }
            return ($o -ge $m)
        }
    }
    throw "Unknown Expect operator '$op'"
}

function Invoke-Check {
    <# Runs one check and returns a result object. Status is one of:
       Pass | Fail | Warn | Info | Skipped | Error #>
    param(
        [Parameter(Mandatory)][hashtable]$Check,
        [Parameter(Mandatory)][string]$Platform,
        [switch]$Connect,
        [hashtable]$Fixture
    )

    $r = [ordered]@{
        Id = $Check.Id; Feature = $Check.Feature; Title = $Check.Title
        Status = $null; Severity = $Check.Severity; Observed = $null
        Message = $null; Fix = $Check.Fix; DocLink = $Check.DocLink
    }

    if ($Check.Platform -ne 'Both' -and $Platform -ne 'Unknown' -and $Check.Platform -ne $Platform) {
        $r.Status = 'Skipped'; $r.Message = "Applies to $($Check.Platform) only (this host: $Platform)"
        return [pscustomobject]$r
    }
    if ($Check.Scope -eq 'Cloud') {
        $r.Status = 'Skipped'
        if ($Connect) { $r.Message = 'Cloud checks are not implemented yet (milestone 3)' }
        else          { $r.Message = 'Cloud check: run with -Connect' }
        return [pscustomobject]$r
    }

    $probe = Invoke-Probe -Probe $Check.Probe -Fixture $Fixture
    $r.Observed = $probe.Value
    if ($probe.Error) {
        $r.Status = 'Error'; $r.Message = "Probe failed: $($probe.Error)"
        return [pscustomobject]$r
    }

    if (Test-Expectation -Observed $probe.Value -Expect $Check.Expect) {
        $r.Status = 'Pass'
        $r.Message = $Check.Title
    } else {
        $r.Status = $Check.Severity   # Fail | Warn | Info
        $r.Message = $Check.WhenFailed
    }
    return [pscustomobject]$r
}

function Get-ExitCode {
    <# 0 = no Fail or Error; 1 = at least one Fail or Error. Warn/Info never fail the run. #>
    param([object[]]$Results)
    $bad = @($Results | Where-Object { $_.Status -eq 'Fail' -or $_.Status -eq 'Error' })
    if ($bad.Count) { return 1 }
    return 0
}

# ---------------------------------------------------------------- output ----

# One place defines what each status looks like. Fail and Warn must never share a colour.
$script:StatusStyle = @{
    Pass    = @{ Tag = ' PASS '; Color = 'Green' }
    Fail    = @{ Tag = ' FAIL '; Color = 'Red' }
    Error   = @{ Tag = ' ERROR'; Color = 'Magenta' }
    Warn    = @{ Tag = ' WARN '; Color = 'Yellow' }
    Info    = @{ Tag = ' INFO '; Color = 'Cyan' }
    Skipped = @{ Tag = ' SKIP '; Color = 'DarkGray' }
}

function Write-Status {
    param([string]$Status, [string]$Text, [switch]$NoColor)
    $s = $script:StatusStyle[$Status]
    if ($NoColor) { Write-Host ("[{0}] {1}" -f $s.Tag.Trim(), $Text); return }
    # Tag on a solid background so FAIL vs WARN is unmissable even on odd terminal themes.
    $bg = $s.Color
    $fg = 'Black'
    if ($Status -eq 'Skipped') { $bg = 'DarkGray'; $fg = 'White' }
    Write-Host $s.Tag -ForegroundColor $fg -BackgroundColor $bg -NoNewline
    Write-Host (" " + $Text) -ForegroundColor $s.Color
}

function Write-Report {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$Platform,
        [switch]$NoColor,
        [switch]$ShowSkipped
    )

    $head = 'Cyan'
    Write-Host ''
    if ($NoColor) { Write-Host "AVD / Windows 365 Feature Validator  -  host platform: $Platform" }
    else { Write-Host "AVD / Windows 365 Feature Validator  -  host platform: $Platform" -ForegroundColor $head }

    # Features in catalog order (Group-Object would sort them alphabetically).
    $features = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Results) { if (-not $features.Contains($r.Feature)) { $features.Add($r.Feature) } }

    foreach ($feature in $features) {
        $group = @($Results | Where-Object Feature -eq $feature)
        $visible = @($group | Where-Object { $ShowSkipped -or $_.Status -ne 'Skipped' })
        if (-not $visible.Count) { continue }
        Write-Host ''
        if ($NoColor) { Write-Host "== $feature ==" } else { Write-Host "== $feature ==" -ForegroundColor White }
        foreach ($r in $visible) {
            Write-Status -Status $r.Status -Text ("{0}  {1}" -f $r.Id, $r.Message) -NoColor:$NoColor
            if ($r.Status -in @('Fail', 'Warn', 'Error')) {
                $obs = '<not present>'
                if ($null -ne $r.Observed) { $obs = "$($r.Observed)" }
                Write-Host ("         observed: {0}" -f $obs)
                if ($r.Fix) { Write-Host ("         fix:      {0}" -f $r.Fix) }
                Write-Host ("         docs:     {0}" -f $r.DocLink)
            }
        }
    }

    $count = @{}
    foreach ($s in 'Pass', 'Fail', 'Error', 'Warn', 'Info', 'Skipped') {
        $count[$s] = @($Results | Where-Object Status -eq $s).Count
    }
    Write-Host ''
    Write-Host 'Summary: ' -NoNewline
    foreach ($s in 'Fail', 'Error', 'Warn', 'Pass', 'Info', 'Skipped') {
        $txt = "$s $($count[$s])   "
        if ($NoColor) { Write-Host $txt -NoNewline }
        else { Write-Host $txt -NoNewline -ForegroundColor $script:StatusStyle[$s].Color }
    }
    Write-Host ''
    return $count
}
