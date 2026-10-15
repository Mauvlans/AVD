# context-redirection-check

Read-only check that shows, **from inside the remote session**, which redirections
(clipboard, drives, printers, PnP/USB) the session actually got and whether device policy is
blocking them. Built for demoing and troubleshooting **context-based redirection** (preview)
on Windows 365 and Azure Virtual Desktop.

```powershell
powershell -ExecutionPolicy Bypass -File .\Show-RedirectionState.ps1
```

Run it as the signed-in user inside the Cloud PC / session host. No elevation needed.

## What it reports

1. **Device policy:** `fDisableClip`, `fDisableCdm`, `fDisableCpm`, `fDisablePNPRedir` under
   `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`. `Blocked` here is a hard
   block. Context-based redirection can never override it because the most restrictive
   setting wins.
2. **What this session received:** rdpclip running in *this* session, `\\tsclient` drives,
   `(redirected)` printers, redirected PnP/USB devices. Each one shows green ALLOWED or red
   BLOCKED.

Writes `%LOCALAPPDATA%\ContextRedirectionCheck\latest.json`. Exits `1` only if device
policy blocks something. A session-level BLOCKED is not an error; it's the expected result
when connecting from a non-compliant client.

## Demo flow

1. Connect from a **compliant** managed device → run → expect all green.
2. Sign out of the session (sign out, not just disconnect), then connect from a
   **non-compliant** / BYOD device → run → expect red for the redirections you mapped to the
   auth context.

## Why everything is blocked, even from a compliant device

Windows 365 Cloud PCs provisioned or reprovisioned since mid-2025 have clipboard, drive,
printer and USB redirection **disabled by default**
([announcement](https://techcommunity.microsoft.com/blog/windows-itpro-blog/enhanced-security-defaults-for-windows-365-cloud-pcs/4424914)).
"Not configured" in Intune does **not** lift that default. Layer 1 will show `Blocked`, and
the Remote Connection Experience policy has nothing it can allow.

Fix: create an Intune Settings Catalog policy that sets these to **Disabled** ("Do not allow…
= Disabled" means allowed), and assign it to the same Cloud PC device group as the Remote
Connection Experience policy:

- Do not allow Clipboard redirection
- Do not allow drive redirection
- Do not allow client printer redirection
- Do not allow supported Plug and Play device redirection

Then sync **and restart** the Cloud PCs.

## Known limits

- Windows keeps no documented local record of the auth-context decision. It's made by the
  service per connection, so layer 2 (live session state) is the proof, not a flag.
- Clipboard detection checks for `rdpclip` in the current session. With clipboard blocked,
  the process can still start on some builds. Confirm with an actual copy/paste.
- PnP/USB detection is best effort (devices enumerating under RDP/TS buses). An empty result
  can also just mean nothing is plugged in on the client.
- Printers rely on the `(redirected N)` naming that Windows uses for redirected queues.
- To see the decision from the Entra side, check the sign-in logs: **non-interactive**
  sign-ins → resource *Windows Cloud Login* → *Authentication context* details.
  Interactive-only views show almost no Windows App traffic.

## Reference

- [Context-based redirections (preview), Windows 365](https://learn.microsoft.com/windows-365/enterprise/context-based-redirections)
- [Context-based redirections (preview), AVD](https://learn.microsoft.com/azure/virtual-desktop/context-based-redirections-avd)
- [Remote Connection Experience](https://learn.microsoft.com/windows-365/enterprise/remote-connection-experience)
