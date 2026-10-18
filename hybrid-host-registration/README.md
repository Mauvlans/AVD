# Register an existing AVD Hybrid session host

This is a **post-boot** workflow, not a VM/image/host-pool installer. Tether (or your own provisioning flow) creates and starts the Windows host. These scripts probe it over PowerShell remoting, optionally run an **operator-supplied** Azure Arc onboarding script, then use Azure PowerShell **on the operator machine** to apply the AVD Arc extension. The registration token is passed only in the extension's protected settings, never to the guest or a checked-in config file.

Microsoft references: [AVD Hybrid deployment](https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-virtual-desktop-hybrid), [Arc onboarding script](https://learn.microsoft.com/en-us/azure/azure-arc/servers/onboard-portal), [PowerShell SSH remoting](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/ssh-remoting-in-powershell).

## Prerequisites

- Existing **standard** AVD host pool (no Session Host Configuration), application group and workspace. The pool must have a managed identity with Reader (or Contributor/Owner) on the Arc machines' resource group or subscription. This script **does not** create those resources or grant permissions.
- AD domain-joined Windows host with working WinRM (Kerberos on a trusted domain) or Windows OpenSSH server configured with a **PowerShell SSH subsystem**. SSH username/key configuration lives on the operator machine. This first version deliberately fails closed on Entra-only joins or hosts whose identity cannot be resolved to a full DNS name.
- Administrator rights on the guest if Arc onboarding is needed. The host must meet Microsoft's [AVD Hybrid prerequisites](https://learn.microsoft.com/en-us/azure/virtual-desktop/hybrid-overview) and reach the required Azure endpoints.
- On the operator machine: PowerShell 7.2+, `Az.Accounts`, `Az.Resources`, `Az.DesktopVirtualization`, `Az.ConnectedMachine`; sign in with `Connect-AzAccount`, then **explicitly** select the target subscription using `Set-AzContext -Subscription <id>`. A mismatched context is rejected.
- If not already Arc-connected: generate/review an Arc onboarding PowerShell script using Microsoft's Azure Arc portal, keep it **outside this repo**, and supply its local path. It executes remotely as your session identity; its installation and authorization are governed by that script. Do not put onboarding tokens or service-principal secrets in a public repo or shell history. `-WhatIf` does not run it.

## Run

```powershell
# Optional local read-only guest check (or invoke it through your own remoting):
.\Test-AvdHybridHost.ps1

$params = @{
  ComputerName = 'sessionhost01.example.com'
  Transport = 'WinRM'                         # or SSH with -SSHUserName
  SubscriptionId = '<subscription-guid>'
  HostPoolResourceGroup = '<host-pool-rg>'
  HostPoolName = '<existing-host-pool>'
  ArcResourceGroup = '<arc-machines-rg>'
}
.\Register-AvdHybridHost.ps1 @params -WhatIf
.\Register-AvdHybridHost.ps1 @params -Confirm:$false

# For SSH, change Transport to SSH and set SSHUserName; for Arc onboarding:
# $params.ArcOnboardingScriptPath = 'C:\secure\OnboardingScript.ps1'
```

The script performs read-only guest/host-pool/identity/Arc checks before writes, creates a fresh one-hour registration token only when the extension is absent, applies `Microsoft.AzureVirtualDesktop.CloudDeviceExtension`, then polls **the host pool** for that host's `Available` status. An extension reporting `Succeeded` is *not* proof of registration. Existing `Available` hosts return `Changed=False`; existing non-Succeeded extensions fail for manual review. Timeout fails rather than reporting false success. Azure operations run with your signed-in Azure context, not via the guest.

**Limits:** Role preflight recognizes built-in Reader/Contributor/Owner on the Arc resource group or subscription. Custom roles and management-group inheritance require manual review and currently fail closed. The guest probe checks agent installation; it does not independently prove the guest's Arc resource ID matches the Azure record. Confirm that identity in `azcmagent show` before registration if hostnames might have been reused. Onboarding script execution is operator-controlled and not an idempotent installer implemented here. There is no live Azure/Windows integration test in this repo; pilot on a disposable host first.

## Offline tests

```powershell
pwsh -NoProfile -File .\Tests\Test-HostPreflight.ps1
pwsh -NoProfile -File .\Tests\Test-Registration.ps1
```

These use test doubles for Azure and remoting; they never touch tenant resources.
