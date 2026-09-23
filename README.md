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
finding. Changes nothing. See the folder's own README for detail and known limits.

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
