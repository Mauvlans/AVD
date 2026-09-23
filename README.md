# AVD

Working tools and scripts for **Azure Virtual Desktop** and **Windows 365** — session
host troubleshooting, client-side toggles, and deployment artifacts. Everything here is
meant to be copied to a machine and run directly. No agent, no packaging, no modules to
install unless a tool says otherwise.

> Most of these touch the registry or read machine-scoped state. Run from an elevated
> prompt, on the machine that actually has the problem.

## Contents

### `drive-redirection-diagnostic/`
Read-only PowerShell diagnostic for the classic *"drive redirection is configured
correctly but drives never appear / RemoteApp just spins"* case. Run it on the **session
host**, ideally while the affected user is signed in.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-AvdDriveRedirection.ps1 -UserName jsmith
```

Checks the effective custom RDP properties (`drivestoredirect`, `redirectdrives`, …),
host-side Terminal Services policy including values set locally rather than by GPO, the
RDPDR channel and `UmRdpService`, FSLogix container health (`Profile_Status.txt`, Cloud
Cache, stale `Terminal Server Client` keys), and RemoteApp vs full-desktop mode. Writes a
console summary plus `C:\ProgramData\AvdDriveCheck\latest.json`; exits `1` on any blocking
finding. Every blocking finding prints the Microsoft Learn page that resolves it, and the
links are collected in the JSON under `DocLinks`. Changes nothing. See the folder's own
README for detail and known limits.

### `redirection-apply/`
Interactive script to **enable or disable RDP redirections** (drive, clipboard, printer,
PnP) across AVD host pools and Windows 365 Cloud PCs. Device-code auth, per-change
confirmation showing BEFORE → AFTER, every write verified by reading it back from the API.

```powershell
.\Set-AvdW365Redirection.ps1 -DryRun    # show what would change, write nothing
.\Set-AvdW365Redirection.ps1            # interactive, confirm each change
```

Handles **both** gates, because the most restrictive one wins: the OS policy
(`fDisableCdm` et al, via Intune) *and* the AVD host pool RDP properties. Setting only
the host pool property is the most common reason "I enabled drive redirection and nothing
changed." Note that Windows 365 provisioning policies contain no redirection settings at
all — W365 is Intune/GPO only. Ships with a 17-case offline test suite pinning the
"Do not allow…" policy inversion. See the folder README for the full limits list.

### `HEVC444.bat`
Toggles the **HEVC 4:4:4 private preview** on and off. Interactive `1` = enable,
`2` = disable. Enables hardware encode preference, sets `EnableHEVC444Threshold`, and
raises `ImageQuality`; the disable path restores the standard profile. Run on the
**session host** as admin, then disconnect and reconnect the session for it to take
effect. Preview feature — expect it to move.

### `SelfHost.Bat`
Flips the **Windows 365 client into the selfhost environment** and back. Interactive
`1` = on (writes `HKCU\SOFTWARE\Microsoft\Windows365\Environment = 0`), `2` = off
(deletes the value, returning to production). `HKCU`, so it applies per-user on the
**client** machine, no elevation needed.

### `Configuration.zip`
The AVD **session host configuration / DeployAgent bundle** used by the ARM host-pool
deployment (`Configuration.ps1`, `Script-SetupSessionHost.ps1`, `AvdFunctions.ps1`,
`Functions.ps1`, plus `DeployAgent.zip`). Kept here so a deployment can be pointed at a
pinned, known copy instead of whatever the public artifact URL currently serves. Unzip
and read `Script-TestSetupSessionHost.ps1` before using it anywhere real — this is a
snapshot, not the latest Microsoft release.

## Conventions

- Scripts that only *read* state say so and never mutate; anything that writes is either
  a `.bat` toggle with an explicit off path, or documents what it changes.
- Diagnostics emit JSON alongside console output so results can be attached to a ticket.
- Exit `0` = healthy / nothing to do, exit `1` = something needs attention.

Provided as-is. Test in a pilot host pool before running against production session hosts.
