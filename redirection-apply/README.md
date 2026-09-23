# Set-AvdW365Redirection.ps1

Interactive script to **enable or disable RDP redirections** across Azure Virtual Desktop
host pools and Windows 365 Cloud PCs. Device-code auth, per-change confirmation showing
BEFORE → AFTER, every write verified by reading back from the API.

```powershell
# see what it would do, change nothing
.\Set-AvdW365Redirection.ps1 -DryRun

# interactive, confirm each change
.\Set-AvdW365Redirection.ps1

# block instead of enable
.\Set-AvdW365Redirection.ps1 -Disable
```

## Read this before running: redirection has two gates

Redirection is controlled in two independent places and **the most restrictive wins**:

| Gate | Where | Set by |
|---|---|---|
| a. OS policy | Session host / Cloud PC (`fDisableCdm`, `fDisableClip`, …) | Intune or Group Policy |
| b. RDP property | AVD host pool (`drivestoredirect:s:*`, …) | Azure portal / ARM |

If a security baseline (CIS Level 1 recommends exactly this) sets `fDisableCdm = 1`,
**setting the host pool RDP property does nothing**. This is the single most common
reason "I enabled drive redirection and nothing changed."

The script handles both halves and will not report success on (b) alone. If you skip the
Intune half it warns you explicitly.

## What it asks you

1. **Platform** — AVD, Windows 365, or both.
2. **Which redirections** — drive, clipboard, printer, PnP. Each is confirmed separately,
   both at selection time and again per-change.
3. **Scope** — all host pools, one host pool, or (for W365) a provisioning policy used to
   enumerate Cloud PCs.
4. **Every change** — shown as BEFORE → AFTER, requires an explicit `y`.

## Limits — these are real constraints, not missing features

- **Windows 365 provisioning policies contain no redirection settings.** The
  `cloudPcProvisioningPolicy` schema is image / naming / domain-join / SSO / autopatch.
  There is no W365 equivalent of host pool RDP properties — Learn is explicit that W365
  redirection is configured *only* via Intune or Group Policy. The script uses a
  provisioning policy solely to **list its Cloud PCs** so you can size the assignment
  group. It cannot "apply redirection to a provisioning policy."
- **Intune assignment targets Entra groups, not device lists.** The script
  creates-or-reuses a named group (`-GroupName`, default
  `AVD-W365-Redirection-Enabled`) and reports the ID. **You add the members.** A freshly
  created group is empty and the policy applies to nothing until you populate it.
- **Two separate device-code sign-ins.** The Azure CLI first-party app does not carry
  `DeviceManagementConfiguration.ReadWrite.All`, so its token returns 403 on the Intune
  half. AVD/ARM uses `az login --use-device-code`; Intune/Graph uses
  `Connect-MgGraph -UseDeviceAuthentication`. Device codes expire after ~120 seconds of
  inactivity — be at the keyboard. The script pauses and warns before generating the
  second one.
- **OS policy changes need a restart** of the session host / Cloud PC. The script says so
  and does not reboot anything.
- Settings-catalog IDs are **resolved against the live catalog at runtime** rather than
  hardcoded. A guessed `settingDefinitionId` reads plausible and fails at policy-create
  time with an opaque error, so each is proven to exist and its real choice `itemId` read
  from the tenant before use. If one isn't found the script skips it loudly rather than
  guessing.

## The inversion that makes this easy to get backwards

The policies are named negatively. To **enable** a redirection you must set
"Do not allow …" to **Disabled**:

| Intent | Policy state | Option suffix |
|---|---|---|
| Redirection **allowed** | `Do not allow …` = Disabled | `_0` |
| Redirection **blocked** | `Do not allow …` = Enabled | `_1` |

An inverted boolean here reads perfectly fine in a diff and does the exact opposite of
what was asked, so it is pinned by `Tests/Test-RedirectionLogic.ps1`.

## Requirements

- Azure CLI (`az`) for the AVD half
- `Microsoft.Graph.Authentication` module for the Intune half
  (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`)
- Graph scopes requested: `DeviceManagementConfiguration.ReadWrite.All`,
  `Group.ReadWrite.All`, `CloudPC.Read.All`

## Output

Console summary plus a JSON record of every decision and result at
`C:\ProgramData\AvdRedirection\apply-<timestamp>.json`. Exit `0` = no failures,
`1` = at least one change failed or failed read-back verification.

## Verification status

- Parses clean on PowerShell 7.4
- PSScriptAnalyzer: zero Warning/Error findings with the committed
  `PSScriptAnalyzerSettings.psd1` (each exclusion carries a written rationale)
- `Tests/Test-RedirectionLogic.ps1`: 17/17 passing — covers the policy inversion, the
  RDP-property parser including the `;`-inside-a-drive-list ambiguity, lossless round
  trip, and the "never guess an option ID" path

**Not executed against a live tenant.** The Azure and Graph call paths are untested in
anger — run `-DryRun` first, then a single pilot host pool, before any broad change.
