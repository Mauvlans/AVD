<#
    Offline logic tests for Set-AvdW365Redirection.ps1.

    Parsing and PSScriptAnalyzer validate the script as text. Neither catches an
    inverted boolean - and this script has one genuinely confusing inversion:

        "Do not allow drive redirection" = Disabled  ->  redirection ALLOWED
        "Do not allow drive redirection" = Enabled   ->  redirection BLOCKED

    Getting that backwards produces a script that confidently does the exact opposite
    of what the operator asked. These tests pin it down, plus the RDP property parser
    (whose ';' separator is ambiguous with drive lists).

    Run:  pwsh -File ./Tests/Test-RedirectionLogic.ps1
#>

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -ceq "$Actual") {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ("  FAIL  {0}`n        expected '{1}'`n        actual   '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:Fail++
    }
}

# ---- copies of the functions under test (kept byte-identical to the script) ----

function ConvertFrom-RdpPropertyString {
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

function Get-ChoiceOptionId {
    param($Definition, [bool]$WantEnabledPolicy)
    $opts = @()
    if ($Definition.PSObject.Properties.Name -contains 'options') { $opts = @($Definition.options) }
    if (-not $opts) { return $null }
    $suffix = if ($WantEnabledPolicy) { '_1' } else { '_0' }
    $hit = $opts | Where-Object { $_.itemId -like "*$suffix" } | Select-Object -First 1
    if ($hit) { return $hit.itemId }
    return $null
}

Write-Host ""
Write-Host "== RDP property parser ==" -ForegroundColor Cyan

$m = ConvertFrom-RdpPropertyString -Text 'drivestoredirect:s:*;audiomode:i:0'
Assert-Equal 'parses drivestoredirect value'      '*'  $m['drivestoredirect'].Value
Assert-Equal 'parses second property'             '0'  $m['audiomode'].Value
Assert-Equal 'property count'                     2    $m.Count

# THE trap: a drive list contains the same ';' used as the property separator.
$m2 = ConvertFrom-RdpPropertyString -Text 'drivestoredirect:s:C:\;D:\;audiomode:i:0'
Assert-Equal 'drive list is not split apart'      'C:\;D:\'  $m2['drivestoredirect'].Value
Assert-Equal 'property after a drive list still parses' '0' $m2['audiomode'].Value

$m3 = ConvertFrom-RdpPropertyString -Text 'drivestoredirect:s:'
Assert-Equal 'empty drivestoredirect is captured, not dropped' '' $m3['drivestoredirect'].Value
Assert-Equal 'empty value still counts as present' $true ($m3.Contains('drivestoredirect'))

$m4 = ConvertFrom-RdpPropertyString -Text ''
Assert-Equal 'empty input -> empty map'           0    $m4.Count

# round trip must not lose or reorder anything
$orig = 'use multimon:i:1;drivestoredirect:s:*;audiomode:i:0'
Assert-Equal 'round trip is lossless' $orig (ConvertTo-RdpPropertyString -Map (ConvertFrom-RdpPropertyString -Text $orig))

# a property name with a space ("use multimon") must survive
$m5 = ConvertFrom-RdpPropertyString -Text 'use multimon:i:1'
Assert-Equal 'property names containing spaces parse' '1' $m5['use multimon'].Value

Write-Host ""
Write-Host "== policy inversion (the bug class that reads fine in a diff) ==" -ForegroundColor Cyan

# Mock of an ADMX-backed choice setting definition as Graph returns it.
$def = [pscustomobject]@{
    options = @(
        [pscustomobject]@{ itemId = 'device_vendor_msft_policy_config_remotedesktopservices_donotallowdriveredirection_0'; displayName = 'Disabled' }
        [pscustomobject]@{ itemId = 'device_vendor_msft_policy_config_remotedesktopservices_donotallowdriveredirection_1'; displayName = 'Enabled'  }
    )
}

# ENABLE redirection  =>  -Disable NOT passed  =>  WantEnabledPolicy = $false  =>  _0
$enable = Get-ChoiceOptionId -Definition $def -WantEnabledPolicy $false
Assert-Equal 'ENABLING redirection selects the _0 (policy Disabled) option' `
    'device_vendor_msft_policy_config_remotedesktopservices_donotallowdriveredirection_0' $enable

# BLOCK redirection   =>  -Disable passed      =>  WantEnabledPolicy = $true   =>  _1
$block = Get-ChoiceOptionId -Definition $def -WantEnabledPolicy $true
Assert-Equal 'BLOCKING redirection selects the _1 (policy Enabled) option' `
    'device_vendor_msft_policy_config_remotedesktopservices_donotallowdriveredirection_1' $block

Assert-Equal 'the two options are not the same' $true ($enable -ne $block)

# regression: a definition with no options must return null, not a wrong guess
$empty = Get-ChoiceOptionId -Definition ([pscustomobject]@{ displayName = 'x' }) -WantEnabledPolicy $false
Assert-Equal 'definition without options -> null (never guess)' $null $empty

Write-Host ""
Write-Host "== RDP property target values ==" -ForegroundColor Cyan

# Mirrors $RedirectionCatalog. ENABLE -> RdpEnable, -Disable -> RdpDisable.
$cat = @(
    [pscustomobject]@{ Key='Drive';     RdpProp='drivestoredirect'; RdpEnable='*'; RdpDisable='' }
    [pscustomobject]@{ Key='Clipboard'; RdpProp='redirectclipboard'; RdpEnable='1'; RdpDisable='0' }
    [pscustomobject]@{ Key='PnP';       RdpProp=$null;               RdpEnable=$null; RdpDisable=$null }
)
Assert-Equal 'enable drive  -> *' '*' ($cat | Where-Object Key -eq 'Drive').RdpEnable
Assert-Equal 'disable drive -> empty (which is what BLOCKS it)' '' ($cat | Where-Object Key -eq 'Drive').RdpDisable
Assert-Equal 'PnP has no host pool RDP property' $null ($cat | Where-Object Key -eq 'PnP').RdpProp

Write-Host ""
if ($script:Fail -gt 0) {
    Write-Host "$($script:Pass) passed, $($script:Fail) FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "$($script:Pass) passed, 0 failed" -ForegroundColor Green
    exit 0
}
