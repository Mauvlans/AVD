# feature-validator — plan

Status: **plan only**. Nothing here runs yet.

A read-only validator that runs **on an AVD session host or Windows 365 Cloud PC** and
reports, feature by feature, whether that feature can work on this machine right now, and
if not, what's blocking it. An optional `-Connect` mode adds the cloud side (Entra
Conditional Access, Intune / Cloud PC settings, sign-in logs) for features whose truth lives
there.

## Why

Diagnosing context-based redirection needed four sources lined up by hand: local RDS
policy, the Intune Remote Connection Experience assignment, the Conditional Access policy,
and non-interactive Entra sign-in logs. The cause turned out to be a W365
secure-by-default block (`fDisableClip=1`) that was visible locally the whole time. A
validator would have found it in seconds.

## Decisions

| Decision | Choice |
|---|---|
| Where it runs | Session host / Cloud PC only. Client-side checks are out of scope. |
| Cloud side | Optional `-Connect` (device-code, delegated, read-only scopes). Local checks never need sign-in. |
| Mutations | None, ever. Fixes are printed with a Learn link; `redirection-apply/` stays the tool that writes. |
| Output | Console summary + JSON (`%ProgramData%\FeatureValidator\latest.json`), same convention as `drive-redirection-diagnostic/`. Exit `0` healthy, `1` any `Fail`. |
| Packaging | Start as a PowerShell script/module. **Not ps2exe**: it's flagged by Defender/AV constantly. If an EXE is needed later: .NET 8 single-file reading the *same* check catalog. Decide after v1. |
| Home | `Mauvlans/AVD/feature-validator/` (public). No tenant-specific values in code, tests or examples. |

## Architecture: checks are data

The engine is small; features are added as catalog entries, so the PowerShell and any
future .NET runner share one source of truth.

```
feature-validator/
  Invoke-FeatureValidator.ps1     # engine: load catalog, run probes, evaluate, report
  checks/
    redirection.psd1              # one file per feature
    shortpath.psd1
    teams.psd1
    ...
  probes/                         # reusable local probes (registry, service, file, process, event log, wmi)
  cloud/                          # -Connect probes (Graph), only loaded when -Connect is passed
  Tests/                          # offline tests: catalog schema + evaluation logic with fixture data
```

Check entry shape:

```powershell
@{
  Id          = 'REDIR-001'
  Feature     = 'Redirection'
  Title       = 'Clipboard redirection not blocked by device policy'
  Platform    = 'Both'            # AVD | W365 | Both
  Scope       = 'Local'           # Local | Cloud (Cloud requires -Connect)
  Probe       = @{ Type = 'Registry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fDisableClip' }
  Expect      = @{ NotEqual = 1 }
  Severity    = 'Fail'            # Fail | Warn | Info
  WhenFailed  = 'Device policy blocks clipboard; context-based redirection and RDP properties cannot override it.'
  Fix         = "Set 'Do not allow Clipboard redirection' to Disabled (Intune Settings Catalog)."
  DocLink     = 'https://learn.microsoft.com/windows-365/enterprise/context-based-redirections'
}
```

Probe types are a closed set (Registry, Service, File, Process, EventLog, Cim, Command,
Graph). Anything that doesn't fit a probe type gets a new probe type, not inline script
in the catalog. That keeps the catalog portable to .NET.

Platform detection is automatic (W365 vs AVD via RDAgent/registry markers) and checks for
the other platform are skipped, not failed.

## v1 feature list

Ordered by value and how stable the feature is.

1. **Redirection**: clipboard/drive/printer/PnP device-policy blocks, W365 secure-by-default,
   directional clipboard. Port from `context-redirection-check/` and `redirection-apply/`.
2. **Context-based redirection**: local layer from (1) + `-Connect`: auth context exists,
   CA policy targets it, RCE (W365) assignment includes this device, recent Windows Cloud
   Login sign-ins show the context being requested (non-interactive logs).
3. **RDP Shortpath**: UDP listener/policy, firewall, recent connections' transport.
4. **Teams optimization**: SlimCore / new media optimization present, WebRTC redirector
   state (WebRTC optimization is retiring — flag it).
5. **Multimedia redirection**: MMR host component installed and version.
6. **SSO**: Entra SSO / Kerberos prerequisites, Windows Cloud Login.
7. **FSLogix**: reuse the logic in `drive-redirection-diagnostic/` (profile status, Cloud
   Cache, VHD locks).
8. **Watermarking / screen capture protection**: policy present and consistent.

Later candidates: HEVC/graphics, input protection (preview), Windows 365 Boot/Switch
host-side state, agent/stack health (RDAgent, BootLoader, SxS).

## Milestones

1. **Engine + catalog schema + tests.** Ship with checks 1 only. Offline tests prove
   evaluation logic against fixture data (the mock proves logic, not that a real host
   behaves; say so in the README).
2. **Checks 3–8 (local).** Run on one real Cloud PC and one real AVD host before calling
   each feature done.
3. **`-Connect`.** Read-only Graph; checks 2 cloud side. Document scopes.
4. **Packaging decision** (signed module vs .NET single-file), based on how people actually
   run it.

## Open questions

- Minimum PowerShell: 5.1 (in-box everywhere) is the assumption; nothing in v1 should need 7.
- Which Graph app for `-Connect`: Microsoft Graph PowerShell's public client vs a dedicated
  app registration. The Azure CLI app can't get CloudPC/Policy scopes (AADSTS65002).
- Whether to run on multi-session hosts per user session or once per host with per-session
  results for the redirection layer.
