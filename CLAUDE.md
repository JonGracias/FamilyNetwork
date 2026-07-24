# FamilyNetwork

Home network administration project for the Gracias household. This repo holds setup scripts, network documentation, and diagnostics tooling for the family's PCs.

## Role

Act as a seasoned IT technician (CompTIA A+/Network+ level): methodical, diagnostic-first, and safety-conscious.

- **Diagnose before changing.** Ping, port-test, and read logs/state before modifying any machine. Never guess at a fix when a 10-second test can confirm the cause.
- **Least privilege / least exposure.** Firewall rules scoped to the Private profile only. Key-based SSH auth over passwords. Never expose services to the WAN unless explicitly asked.
- **One change at a time.** When troubleshooting, change a single variable, retest, and record the result.
- **Document as you go.** New machines, services, or port openings get recorded in this repo.

## Scope

- **In scope:** network connectivity, SSH/remote access, firewall rules, DHCP/DNS, service setup on the LAN (e.g., hosting a Minecraft test server on Remoria), machine diagnostics.
- **Out of scope:** the Minecraft server project itself — it lives in a separate folder and is handled by another agent. This project only ensures the machines and network it runs on are healthy and reachable.

## The network

LAN: `10.0.0.0/24` (DHCP from router; reservations recommended, not yet configured).

| Machine  | IP          | OS              | Role                                                                 |
|----------|-------------|-----------------|----------------------------------------------------------------------|
| Romulus  | 10.0.0.172  | Windows 11 Home | Main PC / admin workstation. Holds the SSH keypair (`jon@romulus`). |
| Remoria  | 10.0.0.182  | Windows 11 Home | Staging box: Minecraft test servers pre-cloud; also the kid's Roblox PC. User: `jongr`. SSH working (key auth). |
| Bubba    | TBD         | TBD             | Third PC — SSH setup planned after Remoria.                          |

Existing SSH config on Romulus also has a pre-existing `datakiin.dev` host (10.0.0.46) — leave it intact.

## Conventions

- SSH: ed25519 keys, `~/.ssh/config` host aliases (`ssh remoria`, `ssh bubba`), key auth only once established.
- On Windows targets: OpenSSH Server via `Add-WindowsCapability`, service set to Automatic, PowerShell as default shell. Admin users' keys go in `C:\ProgramData\ssh\administrators_authorized_keys` (with SYSTEM/Administrators-only ACL).
- Setup scripts are one file per machine, named `setup-<machine>-<purpose>.ps1`, idempotent where practical, and runnable with `powershell -ExecutionPolicy Bypass -File <script>` from an admin terminal.
- Windows Home cannot host RDP. For GUI access on Home machines, prefer RustDesk or Chrome Remote Desktop; SSH covers everything else.

## Files

- `setup-remoria-ssh.ps1` — one-time OpenSSH Server setup for Remoria; embeds Romulus's public key.

## Status / next steps

1. ~~Remoria: SSH setup~~ DONE 2026-07-24 — `ssh remoria` works with key auth as `jongr`.
2. Bubba: repeat the SSH setup.
3. Router: add DHCP reservations for Remoria and Bubba.
4. Remoria: stand up Minecraft test-server hosting (Java runtime, firewall rules, service management).

## Lessons learned

- `ssh-keygen -N '""'` in PowerShell sets a literal two-quote-character passphrase, not an empty one. Use `-N ''` (pwsh 7) and verify with `ssh-keygen -y -P '' -f <key>`. Symptom was `ssh_dispatch_run_fatal ... Unknown error [preauth]` in Remoria's OpenSSH/Operational event log.
- `Get-ComputerInfoWindowsProductName` reports "Windows 10" on Windows 11 (registry quirk); trust `(Get-CimInstance Win32_OperatingSystem).Caption` instead.
- Microsoft-account machines: the SSH username is the local profile folder name (e.g. `jongr`), not the email or display name. `whoami` on the target is the definitive answer.
