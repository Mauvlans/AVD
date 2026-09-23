# AVD drive-redirection diagnostic (standalone)

Single PowerShell script. No Intune, no modules required, no agent. Copy it to the
**AVD session host** and run as administrator, ideally while the affected user is
signed in.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-AvdDriveRedirection.ps1 -UserName jsmith
```

Optional — pull the authoritative custom RDP properties straight from Azure
(requires `Az.DesktopVirtualization` + `Connect-AzAccount`):

```powershell
.\Test-AvdDriveRedirection.ps1 -UserName jsmith -HostPoolName hp-prod -ResourceGroup rg-avd
```

## What it checks

1. **Custom RDP properties** as the host actually received them (`drivestoredirect`,
   `redirectdrives`, `redirectcomports`, `redirectsmartcards`, `redirectprinters`).
   Empty `drivestoredirect:s:` or `redirectdrives:i:0` = blocking.
2. **Host-side policy** — `fDisableCdm` and friends in both the Policies hive
   (GPO/Intune) and the local Terminal Server hive. A GPO that's "clean" at the OU
   can still be set locally or by a baseline.
3. **RDPDR channel** — `rdpdr` driver state, `UmRdpService`, whether any
   `\\tsclient\` drives are currently mapped, and redirection errors in the last 24h.
4. **FSLogix** — container mode/locations, Cloud Cache, `frxsvc`, every
   `Profile_Status.txt` on the box scanned for `LoadTimeExceeded` / `MountPointError` /
   `Locked` / `Corrupt`, FSLogix operational log errors, and stale
   `Terminal Server Client` keys in the user's loaded hive.
5. **RemoteApp vs full desktop** — `rdpshell.exe`/`rdpinit.exe` presence and the host
   pool's `preferredAppGroupType`.
6. **Session/client context** — `Win32_TSClientSetting`, AVD agent version, `quser`.

Read-only. It never resets a profile or edits RDP properties.

## Microsoft Learn links

Every blocking finding and most warnings print a **Microsoft Learn link that resolves
that specific finding**, in magenta under the finding and again as a de-duplicated list
in the summary. The same list is in the JSON under `DocLinks`, and each entry in
`Blocking` / `Warnings` carries its own `Fix:` / `Ref:` URL — so a ticket gets the
remedy, not just the symptom.

Mapping:

| Finding | Learn page |
|---|---|
| `fDisableCdm = 1` / redirection policy | [Configure drive redirection via Intune or Group Policy](https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage#configure-drive-redirection-using-microsoft-intune-or-group-policy) |
| Other `fDisable*` policy values | [RemoteDesktopServices Policy CSP](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-remotedesktopservices#donotallowdriveredirection) |
| Empty / partial `drivestoredirect` | [Configure drive redirection via host pool RDP properties](https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage#configure-drive-redirection-using-host-pool-rdp-properties) |
| RDP property syntax / values | [Supported RDP properties](https://learn.microsoft.com/azure/virtual-desktop/rdp-properties#drivestoredirect) |
| No properties found locally | [Set custom RDP properties on a host pool](https://learn.microsoft.com/azure/virtual-desktop/customize-rdp-properties) |
| RDPDR / `UmRdpService` | [Redirection over RDP](https://learn.microsoft.com/azure/virtual-desktop/redirection-remote-desktop-protocol) |
| FSLogix profile unhealthy | [FSLogix logging and diagnostics](https://learn.microsoft.com/fslogix/troubleshooting-events-logs-diagnostics) |
| FSLogix error events | [FSLogix known issues](https://learn.microsoft.com/fslogix/troubleshooting-known-issues) |
| Cloud Cache in use | [Cloud Cache containers](https://learn.microsoft.com/fslogix/tutorial-cloud-cache-containers) |
| RemoteApp mode | [Publish applications as RemoteApp](https://learn.microsoft.com/azure/virtual-desktop/publish-applications-stream-remoteapp) |

All verified HTTP 200 at time of writing. Microsoft moves docs — if one 404s, the anchor
is the part most likely to have changed, not the page.

Output: console summary (green/yellow/red) plus a full JSON report at
`C:\ProgramData\AvdDriveCheck\latest.json`. Send that JSON back for analysis.

Exit code `0` = no blocking findings, `1` = at least one blocker.

## Known limits

- The RDP property string is split on `;`, which is also the separator inside a
  drive list (`drivestoredirect:s:C:\;D:\`). A specific drive list is therefore
  reported as a warning, not parsed into individual drives — which is the correct
  action anyway (it should be `*` for "drives connected later").
- If the user isn't logged on when it runs, FSLogix `Profile_Status.txt` and the
  redirected-drive check have nothing to look at. Run it during a live repro.
- It reads the RDP properties the *agent cached locally*; if that key is absent it
  says so. Use `-HostPoolName`/`-ResourceGroup` for the authoritative value.
