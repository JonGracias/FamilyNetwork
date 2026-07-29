# FamilyNetwork

Setup scripts and network documentation for the home network (Romulus, Remoria, Bubba).

## Remoria: one-time SSH server setup

On **Remoria**, open Terminal as Administrator (right-click Start → **Terminal (Admin)**) and paste:

```powershell
irm https://raw.githubusercontent.com/JonGracias/FamilyNetwork/main/setup-remoria-ssh.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

This installs OpenSSH Server, starts it permanently, opens firewall port 22 (private network only), authorizes Romulus's SSH key for passwordless login, and sets PowerShell as the default shell. At the end it prints the machine's Windows edition, username, and IP — note those down.

Afterwards, from Romulus:

```powershell
ssh remoria
```

## Bubba: one-time SSH server setup

On **Bubba**, open Terminal as Administrator (right-click Start → **Terminal (Admin)**) and paste:

```powershell
irm https://raw.githubusercontent.com/JonGracias/FamilyNetwork/main/setup-bubba-ssh.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

When it finishes, report the **SSH username** line back — that's the name Romulus connects as.

## Diagnostics

Two read-only health checks, runnable on any machine. From Romulus, over SSH (piping to `powershell -Command -` mangles multi-line scripts — encode instead):

```powershell
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-Content .\diag-system.ps1 -Raw)))
ssh remoria "powershell -NoProfile -EncodedCommand $b64"
```

- `diag-system.ps1` — general health: OS/CPU/RAM/disks, Java, network, firewall, sshd, power plan, recent System-log errors, pending reboot.
- `diag-disk.ps1` — storage deep-dive: SMART raw attributes (CRC/G-sense/reallocated), dirty-shutdown forensics, disk-error history. Use when a machine freezes or drops I/O.

Swap the script name and host alias (`remoria`, `bubba`) as needed. Both scripts only read state — safe to run while the machine is in use.

## Addressing: no DHCP reservations available

Comcast/Xfinity no longer exposes reserved-IP assignment on this plan, so machine IPs can change. Rather than chase them, `~/.ssh/config` on Romulus points at **machine names**, which resolve on the LAN and follow the machine if its address changes:

```
Host remoria
  HostName remoria      # not 10.0.0.182
  User jongr
```

Check resolution at any time with `Resolve-DnsName remoria` (`remoria.local` also works). Current addresses, for reference and as fallback if a name ever stops resolving:

| Device  | IP (current)| MAC address         |
|---------|-------------|---------------------|
| Romulus | 10.0.0.172  | `7C-B5-66-43-20-4C` |
| Remoria | 10.0.0.182  | `70-15-FB-90-BD-CF` |
| Bubba   | 10.0.0.191  | `30-F6-EF-8B-D3-46` |

Note: `known_hosts` is keyed by the exact string you connect to. After switching an entry from an IP to a name, SSH will report `Host key verification failed` until the key is recorded under the new name — verify with `ssh-keyscan` that it matches the IP's stored key before adding it.
