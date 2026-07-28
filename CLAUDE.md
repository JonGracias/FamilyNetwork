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
| Bubba    | 10.0.0.191  | Windows 11 Home | Third PC. User: `barto`. SSH working (key auth).                     |

Existing SSH config on Romulus also has a pre-existing `datakiin.dev` host (10.0.0.46) — leave it intact.

## Conventions

- SSH: ed25519 keys, `~/.ssh/config` host aliases (`ssh remoria`, `ssh bubba`), key auth only once established.
- On Windows targets: OpenSSH Server via `Add-WindowsCapability`, service set to Automatic, PowerShell as default shell. Admin users' keys go in `C:\ProgramData\ssh\administrators_authorized_keys` (with SYSTEM/Administrators-only ACL).
- Setup scripts are one file per machine, named `setup-<machine>-<purpose>.ps1`, idempotent where practical, and runnable with `powershell -ExecutionPolicy Bypass -File <script>` from an admin terminal.
- Windows Home cannot host RDP. For GUI access on Home machines, prefer RustDesk or Chrome Remote Desktop; SSH covers everything else.

## Files

- `README.md` — copy-paste setup commands for new machines + DHCP reservation table (IPs/MACs).
- `setup-remoria-ssh.ps1` — one-time OpenSSH Server setup for Remoria; embeds Romulus's public key.
- `setup-bubba-ssh.ps1` — same for Bubba; improved summary (real edition via CIM, `whoami`, MAC).
- `diag-system.ps1` — read-only general health check (OS/CPU/RAM/disks, Java, network, firewall, sshd, power plan, recent errors, pending reboot). Machine-agnostic; run on any box.
- `diag-disk.ps1` — read-only storage deep-dive: disk→letter map, SMART raw attributes, dirty-shutdown forensics (Event 41 BugcheckCode/PowerButtonTimestamp), Event 153/140/129 history.

Repo is public at https://github.com/JonGracias/FamilyNetwork — new machines fetch setup scripts with `irm` from raw.githubusercontent.com. Nothing secret goes in this repo (public keys are fine; passwords/private keys never).

## Status / next steps

1. ~~Remoria: SSH setup~~ DONE 2026-07-24 — `ssh remoria` works with key auth as `jongr`.
2. ~~Bubba: SSH setup~~ DONE 2026-07-24 — `ssh bubba` works with key auth as `barto`.
3. Router: add DHCP reservations for Remoria and Bubba.
4. Remoria: fix D: SATA connection. Diagnosed 2026-07-28: daily freezes (8 dirty boots/week, kid held power button) traced to the 2 TB Seagate ST2000DM008 (Disk 0 = D:) — 2,336 UDMA CRC errors (cable fingerprint), zero G-sense/reallocated/pending (not drop damage, media fine), Event 153 jumped from 5 in 9 months to 872 in the last week of July (onset coincides with in-case power-cable work). Fix: power off, reseat/replace SATA data + power connectors, different mobo port. Verify with `diag-disk.ps1`: CRC count stopped climbing (baseline 2,336) and Event 153 quiet. D: holds only reinstallable game installs, no save data — no backup needed. No Minecraft worlds on D: until verified.
5. ~~Remoria: machine readiness for Minecraft hosting~~ DONE 2026-07-28 — Temurin JDK 21.0.11 LTS installed (system PATH + JAVA_HOME), inbound TCP 25565 open (Private profile, LocalSubnet only). The server itself (install, worlds, service management) is out of scope — separate project/agent. Constraints to pass along: keep worlds on C: until D: is trusted (step 4); box is on Wi-Fi (consider Ethernet for real testing).

## Lessons learned

- `ssh-keygen -N '""'` in PowerShell sets a literal two-quote-character passphrase, not an empty one. Use `-N ''` (pwsh 7) and verify with `ssh-keygen -y -P '' -f <key>`. Symptom was `ssh_dispatch_run_fatal ... Unknown error [preauth]` in Remoria's OpenSSH/Operational event log.
- `Get-ComputerInfoWindowsProductName` reports "Windows 10" on Windows 11 (registry quirk); trust `(Get-CimInstance Win32_OperatingSystem).Caption` instead.
- Microsoft-account machines: the SSH username is the local profile folder name (e.g. `jongr`), not the email or display name. `whoami` on the target is the definitive answer.
- Running multi-line PowerShell over SSH: piping a script to `powershell -Command -` executes it line-by-line and mangles blocks/variables. Base64-encode the script as UTF-16LE and use `powershell -NoProfile -EncodedCommand <b64>` instead (see README "Diagnostics").
- SMART "Healthy" only means no attribute crossed its failure threshold — it stays green through cable faults and stalls. Read the raw counters: 199 (UDMA CRC) = bad SATA data cable/connector, 191 (G-sense) = physical shock, 5/197/198 = failing media. Disk Event 153 storms + climbing CRC with clean media attributes = connection problem, not a dying drive.
- A "frozen" Windows box with no BSOD and no events at freeze time can be a stalled storage device: I/O blocks system-wide and even event logging stops, so the log shows silence before the dirty boot.
