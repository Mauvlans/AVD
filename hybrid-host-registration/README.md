# Register an existing AVD Hybrid session host

This is a **post-boot** workflow, not a VM/image/host-pool installer. Tether (or your own provisioning flow) creates and starts the Windows host. These scripts probe it over PowerShell remoting, use the signed-in operator's Azure PowerShell identity to install/connect Azure Arc **when needed**, then apply the AVD Arc extension. No service-principal secret or pre-generated onboarding script is required for the standard path. The AVD registration token is passed only in the extension's protected settings, never to the guest or a checked-in config file.

Microsoft references: [AVD Hybrid deployment](https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-virtual-desktop-hybrid), [remote Arc onboarding with Azure PowerShell](https://learn.microsoft.com/en-us/azure/azure-arc/servers/onboard-powershell), [PowerShell SSH remoting](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/ssh-remoting-in-powershell).

## Prerequisites

- Existing **standard** AVD host pool (no Session Host Configuration), application group and workspace. The pool must have a managed identity with Reader (or Contributor/Owner) on the Arc machines' resource group or subscription. This script **does not** create those resources or grant permissions.
- AD domain-joined Windows host with working WinRM (Kerberos on a trusted domain) or Windows OpenSSH server configured with a **PowerShell SSH subsystem**. SSH username/key configuration lives on the operator machine. This first version deliberately fails closed on Entra-only joins or hosts whose identity cannot be resolved to a full DNS name.
- Administrator rights on the guest if Arc onboarding is needed. The host must meet Microsoft's [AVD Hybrid prerequisites](https://learn.microsoft.com/en-us/azure/virtual-desktop/hybrid-overview) and reach the required Azure endpoints.
- On the operator machine: PowerShell 7.2+, `Az.Accounts`, `Az.Resources`, `Az.DesktopVirtualization`, `Az.ConnectedMachine`; sign in with `Connect-AzAccount`, then **explicitly** select the target subscription using `Set-AzContext -Subscription <id>`. A mismatched context is rejected. If Arc onboarding is needed, this identity must have **Azure Connected Machine Onboarding** (or Contributor) on the Arc resource group; it also needs the permissions required to create AVD host-pool registration info and Arc extensions.
- For native onboarding of an unregistered host, supply `-ArcLocation` with the Azure region for the Arc machine. Microsoft's `Connect-AzConnectedMachine -PSSession` downloads/installs the agent and connects it using the operator's Azure context. It does not create the resource group. An existing Arc resource with a non-Connected status is refused for manual repair rather than overwritten.
- Optional legacy/custom path: `-ArcOnboardingScriptPath` runs a reviewed local script over remoting instead of the native cmdlet. Keep the file **outside this public repo**; do not put tokens or secrets in shell history. `-WhatIf` does not run it.

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
  ArcLocation = '<azure-region>'               # used only when Arc onboarding is needed
}
.\Register-AvdHybridHost.ps1 @params -WhatIf
.\Register-AvdHybridHost.ps1 @params -Confirm:$false

# For SSH, change Transport to SSH and set SSHUserName.
# Optional custom Arc onboarding instead of the built-in Az cmdlet:
# $params.ArcOnboardingScriptPath = 'C:\secure\OnboardingScript.ps1'
```

The script performs read-only guest/host-pool/identity/Arc checks before writes, installs/connects Arc over a temporary PowerShell session if absent, creates a fresh one-hour AVD registration token only when the extension is absent, applies `Microsoft.AzureVirtualDesktop.CloudDeviceExtension`, then polls **the host pool** for that host's `Available` status. An extension reporting `Succeeded` is *not* proof of registration. Existing `Available` hosts return `Changed=False`; existing non-Succeeded extensions fail for manual review. Timeout fails rather than reporting false success. Azure API calls use the operator's signed-in context; agent installation runs on the guest via remoting.

**Limits:** Role preflight recognizes built-in Reader/Contributor/Owner on the Arc resource group or subscription. Custom roles and management-group inheritance require manual review and currently fail closed. The guest probe checks agent installation; it does not independently prove the guest's Arc resource ID matches the Azure record. Confirm that identity in `azcmagent show` before registration if hostnames might have been reused. Native Arc onboarding uses Microsoft's `Connect-AzConnectedMachine` on the operator machine; the custom-script override remains operator-controlled and is not an installer implemented here. There is no live Azure/Windows integration test in this repo; pilot on a disposable host first.

## Offline tests

```powershell
pwsh -NoProfile -File .\Tests\Test-HostPreflight.ps1
pwsh -NoProfile -File .\Tests\Test-Registration.ps1
```

These use test doubles for Azure and remoting; they never touch tenant resources.
