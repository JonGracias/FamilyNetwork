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

- SSH: ed25519 keys, `~/.ssh/config` host aliases (`ssh remoria`, `ssh bubba`), key auth only once established. `HostName` is the LAN machine name, not an IP — Comcast can't do DHCP reservations, so names keep working when addresses drift.
- On Windows targets: OpenSSH Server via `Add-WindowsCapability`, service set to Automatic, PowerShell as default shell. Admin users' keys go in `C:\ProgramData\ssh\administrators_authorized_keys` (with SYSTEM/Administrators-only ACL).
- Setup scripts are one file per machine, named `setup-<machine>-<purpose>.ps1`, idempotent where practical, and runnable with `powershell -ExecutionPolicy Bypass -File <script>` from an admin terminal.
- Windows Home cannot host RDP. For GUI access on Home machines, prefer RustDesk or Chrome Remote Desktop; SSH covers everything else.

## Files

- `README.md` — copy-paste setup commands for new machines + DHCP reservation table (IPs/MACs).
- `setup-remoria-ssh.ps1` — one-time OpenSSH Server setup for Remoria; embeds Romulus's public key.
- `setup-bubba-ssh.ps1` — same for Bubba; improved summary (real edition via CIM, `whoami`, MAC).
- `diag-system.ps1` — read-only general health check (OS/CPU/RAM/disks, Java, network, firewall, sshd, power plan, recent errors, pending reboot). Machine-agnostic; run on any box.
- `diag-disk.ps1` — read-only storage deep-dive: disk→letter map, SMART raw attributes, dirty-shutdown forensics (Event 41 BugcheckCode/PowerButtonTimestamp), Event 153/140/129 history.
- `setup-ssh-harden.ps1` — disables SSH password + keyboard-interactive auth (key-only). Machine-agnostic; prepends directives above the Match block, backs up sshd_config first.
- `watch-remoria-disk.ps1` — runs on Romulus via Scheduled Task ("FamilyNetwork - Remoria disk watch", Mondays 10:00, auto-expires ~2026-09-01): polls Remoria's CRC counter + Event 153 over SSH, logs to `logs/` (gitignored), writes a desktop ALERT file if CRC climbs.

Repo is public at https://github.com/JonGracias/FamilyNetwork — new machines fetch setup scripts with `irm` from raw.githubusercontent.com. Nothing secret goes in this repo (public keys are fine; passwords/private keys never).

## Status / next steps

1. ~~Remoria: SSH setup~~ DONE 2026-07-24 — `ssh remoria` works with key auth as `jongr`.
2. ~~Bubba: SSH setup~~ DONE 2026-07-24 — `ssh bubba` works with key auth as `barto`.
3. ~~Router: DHCP reservations~~ NOT POSSIBLE 2026-07-29 — Comcast/Xfinity no longer exposes reserved-IP assignment on this plan. Solved differently: `~/.ssh/config` on Romulus now uses LAN machine names (`HostName remoria`) instead of hard-coded IPs, so address drift is self-healing. Verified `remoria`/`bubba` (and `.local`) resolve from Romulus. Fallback IPs kept in a comment in the config. If name resolution ever breaks, next option is static IPs set on each machine outside the DHCP pool.
4. Remoria D: SATA — RESEATED 2026-07-29, under observation. Diagnosis 2026-07-28: daily freezes (8 dirty boots/week, kid held power button) traced to the 2 TB Seagate ST2000DM008 (Disk 0 = D:) — 2,336 UDMA CRC errors (cable fingerprint), zero G-sense/reallocated/pending (not drop damage, media fine), Event 153 jumped from 5 in 9 months to 872 in the last week of July (onset coincided with in-case power-cable work). Jon reseated the connectors and moved the drive to a different mobo port (device path changed `...&0&030000` → `...&0&020000`, confirming the physical change). Post-fix checks: CRC still exactly 2,336 (not climbing), no Event 153/140 since the 12:17 boot, `chkdsk D: /scan` clean (no problems, 0 KB bad sectors, 4-second scan). **Not yet proven** — that was only ~20 min of light uptime; the real test is a few days of gaming load. `watch-remoria-disk.ps1` polls daily until ~2026-08-28 and alerts if CRC climbs. Keep Minecraft worlds off D: until it survives a week of normal use.
5. ~~Remoria: machine readiness for Minecraft hosting~~ DONE 2026-07-28 — Temurin JDK 21.0.11 LTS installed (system PATH + JAVA_HOME), inbound TCP 25565 open (Private profile, LocalSubnet only). The server itself (install, worlds, service management) is out of scope — separate project/agent. Constraints to pass along: keep worlds on C: until D: is trusted (step 4); box is on Wi-Fi (consider Ethernet for real testing).
6. ~~Firewalls re-enabled~~ DONE 2026-07-28 — found Windows Firewall fully DISABLED (Private+Public) on both Remoria and Bubba; re-enabled all profiles on both. Bubba's Wi-Fi was also misclassified Public → set to Private. Open question for the household: who turned them off, and why (game troubleshooting?). Watch that they stay on.
7. ~~SSH hardening~~ DONE 2026-07-28 — `setup-ssh-harden.ps1` run on Remoria and Bubba: password + keyboard-interactive auth off, verified key-only (`Permission denied (publickey)`).
8. Baselines run 2026-07-28 on all three machines (`diag-system.ps1`). Notables: Bubba is an i5-1335U/16GB laptop, healthy, but runs ancient Oracle Java 8 (fine unless something needs newer); Romulus healthy. Remoria disk watch scheduled on Romulus (weekly, auto-expires ~2026-09-01).
9. ~~Remoria: consider Ethernet~~ NOT NEEDED 2026-07-29 — measured instead of assumed: Intel AX210 Wi-Fi 6E on the **6 GHz** band, ch 69, 802.11ax/WPA3, RSSI -46 dBm (90%), 2.4 Gbps rx / 2.16 Gbps tx, 2.0 Gbps link. Romulus→Remoria ICMP: 0% loss, sub-1 ms. TCP-connect latency (spaced samples) 2.7–6.8 ms, sd ~1 ms. 6 GHz is uncongested and far exceeds what a Minecraft server needs (a few kbps/player; latency stability is what matters). No cable run required — closing this.

## Lessons learned

- `ssh-keygen -N '""'` in PowerShell sets a literal two-quote-character passphrase, not an empty one. Use `-N ''` (pwsh 7) and verify with `ssh-keygen -y -P '' -f <key>`. Symptom was `ssh_dispatch_run_fatal ... Unknown error [preauth]` in Remoria's OpenSSH/Operational event log.
- `Get-ComputerInfoWindowsProductName` reports "Windows 10" on Windows 11 (registry quirk); trust `(Get-CimInstance Win32_OperatingSystem).Caption` instead.
- Microsoft-account machines: the SSH username is the local profile folder name (e.g. `jongr`), not the email or display name. `whoami` on the target is the definitive answer.
- Running multi-line PowerShell over SSH: piping a script to `powershell -Command -` executes it line-by-line and mangles blocks/variables. Base64-encode the script as UTF-16LE and use `powershell -NoProfile -EncodedCommand <b64>` instead (see README "Diagnostics").
- SMART "Healthy" only means no attribute crossed its failure threshold — it stays green through cable faults and stalls. Read the raw counters: 199 (UDMA CRC) = bad SATA data cable/connector, 191 (G-sense) = physical shock, 5/197/198 = failing media. Disk Event 153 storms + climbing CRC with clean media attributes = connection problem, not a dying drive.
- A "frozen" Windows box with no BSOD and no events at freeze time can be a stalled storage device: I/O blocks system-wide and even event logging stops, so the log shows silence before the dirty boot.
- Firewall rules mean nothing if the firewall is off: both kids' PCs had Defender Firewall silently disabled (Private+Public). `Get-NetFirewallProfile` (check `Enabled`) before trusting any rule; also check `Get-NetConnectionProfile` — a home LAN misclassified as Public makes every Private-scoped rule inert. Symptom that gave it away: SSH worked on a box whose only port-22 rule was Private-profile while its network was Public.
- Disabling SSH password auth on Windows needs BOTH `PasswordAuthentication no` and `KbdInteractiveAuthentication no` — keyboard-interactive is the password prompt most clients actually use. Prepend at the top of sshd_config: appending lands inside the trailing `Match Group administrators` block.
- Changing `HostName` in `~/.ssh/config` from an IP to a name breaks login with `Host key verification failed` — known_hosts is keyed by the string you connect to. Don't blind-accept the "new" key: confirm `ssh-keyscan <name>` matches the stored entry for the old IP, then copy that verified entry under the new name.
- Benchmark artifacts look like network problems. Back-to-back TCP connects to sshd measured ~10 ms jitter with 50 ms spikes; the same test spaced 500 ms apart gave ~1 ms sd. The spikes were sshd/firewall handling a connect flood, not the Wi-Fi. Space out samples before concluding the link is bad — and don't "fix" a setting based on the fast-loop number.
- SMART attribute InstanceName encodes the SATA port (`...&0&030000` vs `...&0&020000`). Handy for confirming someone actually moved a drive to a different port.
