<h1>Microsoft Managed Desktop Enrollment API</h1>

Windows Autopatch is a cloud service that automates Windows, Microsoft 365 Apps
for enterprise, Microsoft Edge, and Microsoft Teams updates to improve security
and productivity across your organization. With Azure Virtual Desktop, you can
include Windows Autopatch onboarding as part of your provision process ensuring
your Cloud PCs are always up to date.

This script provides IT teams with the ability to manually register Cloud PCs
with the Windows Autopatch Service using our Enrollment API. This script can be
incorporated into existing provisioning or deployment pipelines for automation.
This script is provided as is, Microsoft Managed Desktop will not provide any
support customizing its contents or adopting to any other workflows.

This script leverages the Az.Accounts Module and should be executed with Intune
Admin permissions, this is required as the scripts will collect Token for the
takeover service.

Dependencies:

-   Module = Az.Accounts

-   Permissions = Intune Admin

To execute simply save and execute the “New-MMDEnrollmentAVD-PublicPreview.ps1”
PowerShell script locally providing the parameter for your Azure AD Device ID.

This script will perform the following actions

1.  Capture Azure AD Device ID
```powershell
    Write-Host Importing Az.Accounts
    Import-Module Az.Accounts -Force
```
2.  Import **Az.Accounts** (if not present will error out)
```powershell
    Write-Host Login with Intune Admin to get the token to post by custom API
    Connect-AzAccount
```
3.  Provide Authentication to Grab Auth Token for API
```powershell
    Write-Host Login with Intune Admin to get the token to post by custom API
    Connect-AzAccount
```
4.  Call Token to the Modern Management Service
```powershell
  $token = Get-AzAccessToken -ResourceUrl "c9d36ed4-91b3-4c87-b8d7-68d92826c96c"
```
5.  Builds Auth Header
```powershell
    $header = @{
        'Content-Type' = 'application/json'
        'Authorization' = "Bearer"+ " " + "$($token.token)"
    }
```
6.  Calls API with Payload
```powershell
    $APIResponse = Invoke-RestMethod -Uri $uri -Method POST -Headers $header -Body $deviceList
```
7.  Ends
```powershell
    return  $APIResponse
```
Example:
```powershell
New-MMDEnrollmentAVDPublicPreview.ps1 “Azure AD Device ID”

New-MMDEnrollmentAVDPublicPreview.ps1 “33e84f7e-e6ee-4904-8767-24d442d270a2”
```

