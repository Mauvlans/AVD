# Redirection: clipboard, drive, printer, PnP/USB.
#
# The "Do not allow ... redirection" policies are inverted: value 1 = BLOCKED.
# Device policy is the most restrictive gate. Host pool RDP properties (AVD) and
# context-based redirection (W365 Remote Connection Experience / AVD RDP properties
# mapped to an auth context) can only narrow what device policy allows, never widen it.
#
# Windows 365 Cloud PCs provisioned or reprovisioned since mid-2025 block all four by
# default. Leaving the Intune setting "Not configured" does not lift that.
@{
    Checks = @(
        @{
            Id         = 'REDIR-001'
            Feature    = 'Redirection'
            Title      = 'Clipboard redirection not blocked by device policy'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fDisableClip' }
            Expect     = @{ NotEqual = 1 }
            Severity   = 'Fail'
            WhenFailed = 'Clipboard redirection is blocked by device policy (fDisableClip=1). RDP properties and context-based redirection cannot override it.'
            Fix        = "Intune Settings Catalog: 'Do not allow Clipboard redirection' = Disabled, assigned to these hosts."
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-clipboard'
        }
        @{
            Id         = 'REDIR-002'
            Feature    = 'Redirection'
            Title      = 'Drive redirection not blocked by device policy'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fDisableCdm' }
            Expect     = @{ NotEqual = 1 }
            Severity   = 'Fail'
            WhenFailed = 'Drive redirection is blocked by device policy (fDisableCdm=1).'
            Fix        = "Intune Settings Catalog: 'Do not allow drive redirection' = Disabled."
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage'
        }
        @{
            Id         = 'REDIR-003'
            Feature    = 'Redirection'
            Title      = 'Printer redirection not blocked by device policy'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fDisableCpm' }
            Expect     = @{ NotEqual = 1 }
            Severity   = 'Fail'
            WhenFailed = 'Printer redirection is blocked by device policy (fDisableCpm=1).'
            Fix        = "Intune Settings Catalog: 'Do not allow client printer redirection' = Disabled."
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-printers'
        }
        @{
            Id         = 'REDIR-004'
            Feature    = 'Redirection'
            Title      = 'Plug and Play / USB redirection not blocked by device policy'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fDisablePNPRedir' }
            Expect     = @{ NotEqual = 1 }
            Severity   = 'Fail'
            WhenFailed = 'Plug and Play device redirection is blocked by device policy (fDisablePNPRedir=1).'
            Fix        = "Intune Settings Catalog: 'Do not allow supported Plug and Play device redirection' = Disabled."
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-usb'
        }
        @{
            Id         = 'REDIR-005'
            Feature    = 'Redirection'
            Title      = 'Clipboard not restricted host-to-client'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'SCClipLevel' }
            Expect     = @{ NotEqual = 0 }
            Severity   = 'Warn'
            WhenFailed = 'Directional clipboard: copying FROM the remote session to the client is disabled (SCClipLevel=0). Clipboard works one way only.'
            Fix        = "If unintended: 'Restrict clipboard transfer from server to client' - raise the level or set Not configured."
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/clipboard-transfer-direction-data-types'
        }
        @{
            Id         = 'REDIR-006'
            Feature    = 'Redirection'
            Title      = 'Clipboard not restricted client-to-host'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'CSClipLevel' }
            Expect     = @{ NotEqual = 0 }
            Severity   = 'Warn'
            WhenFailed = 'Directional clipboard: copying FROM the client INTO the remote session is disabled (CSClipLevel=0). Clipboard works one way only.'
            Fix        = "If unintended: 'Restrict clipboard transfer from client to server' - raise the level or set Not configured."
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/clipboard-transfer-direction-data-types'
        }
        @{
            Id         = 'REDIR-007'
            Feature    = 'Redirection'
            Title      = 'No local (non-policy) clipboard block on the RDP listener'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'; Name = 'fDisableClip' }
            Expect     = @{ NotEqual = 1 }
            Severity   = 'Fail'
            WhenFailed = 'Clipboard is disabled directly on the RDP-Tcp listener (not via policy). Intune/GPO reports will not show this.'
            Fix        = 'Set HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp\fDisableClip to 0 (or remove the image customisation that set it).'
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-clipboard'
        }
        @{
            Id         = 'REDIR-008'
            Feature    = 'Redirection'
            Title      = 'No local (non-policy) drive block on the RDP listener'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Registry'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'; Name = 'fDisableCdm' }
            Expect     = @{ NotEqual = 1 }
            Severity   = 'Fail'
            WhenFailed = 'Drive redirection is disabled directly on the RDP-Tcp listener (not via policy). Intune/GPO reports will not show this.'
            Fix        = 'Set HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp\fDisableCdm to 0.'
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage'
        }
        @{
            Id         = 'REDIR-009'
            Feature    = 'Redirection'
            Title      = 'Remote Desktop Services is running'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Service'; Name = 'TermService' }
            Expect     = @{ Equal = 'Running' }
            Severity   = 'Fail'
            WhenFailed = 'TermService is not running. No RDP session or redirection can work.'
            Fix        = 'Start the Remote Desktop Services service and check the System event log for why it stopped.'
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent'
        }
        @{
            Id         = 'REDIR-010'
            Feature    = 'Redirection'
            Title      = 'UserMode Port Redirector service present'
            Platform   = 'Both'
            Scope      = 'Local'
            Probe      = @{ Type = 'Service'; Name = 'UmRdpService' }
            Expect     = @{ Exists = $true }
            Severity   = 'Fail'
            WhenFailed = 'UmRdpService (Remote Desktop Services UserMode Port Redirector) is missing. Drive and printer redirection depend on it.'
            Fix        = 'Repair the image; the service ships with Windows and should not be removed.'
            DocLink    = 'https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage'
        }

        # ---- Context-based redirection: cloud side (requires -Connect, milestone 3) ----
        @{
            Id         = 'CBR-101'
            Feature    = 'Context-based redirection'
            Title      = 'Authentication context exists and is published to apps'
            Platform   = 'Both'
            Scope      = 'Cloud'
            Probe      = @{ Type = 'Cloud'; Query = 'AuthContexts' }
            Severity   = 'Fail'
            WhenFailed = 'No published authentication context found.'
            Fix        = 'Entra > Conditional Access > Authentication contexts: create one and tick Publish to apps.'
            DocLink    = 'https://learn.microsoft.com/windows-365/enterprise/context-based-redirections'
        }
        @{
            Id         = 'CBR-102'
            Feature    = 'Context-based redirection'
            Title      = 'Conditional Access policy targets the authentication context'
            Platform   = 'Both'
            Scope      = 'Cloud'
            Probe      = @{ Type = 'Cloud'; Query = 'CaPolicyForAuthContext' }
            Severity   = 'Fail'
            WhenFailed = 'No enabled Conditional Access policy targets the authentication context.'
            Fix        = 'Create a CA policy: Target resources = Authentication context, Grant = Require compliant device.'
            DocLink    = 'https://learn.microsoft.com/windows-365/enterprise/context-based-redirections'
        }
        @{
            Id         = 'CBR-103'
            Feature    = 'Context-based redirection'
            Title      = 'Recent connections request the authentication context'
            Platform   = 'Both'
            Scope      = 'Cloud'
            Probe      = @{ Type = 'Cloud'; Query = 'SignInsRequestAuthContext' }
            Severity   = 'Warn'
            WhenFailed = "Windows Cloud Login sign-ins only show the context as 'previouslySatisfied'; nothing is requesting it at connect time."
            Fix        = 'Check the Remote Connection Experience (W365) / RDP properties (AVD) mapping and that device policy does not block the redirection (REDIR-001..004).'
            DocLink    = 'https://learn.microsoft.com/windows-365/enterprise/context-based-redirections'
        }
    )
}
