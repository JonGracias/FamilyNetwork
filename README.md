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

## Router: DHCP reservations

Router admin: http://10.0.0.1 (or the Xfinity app) → **Connected Devices** → select device → **Edit** → IP assignment: **Reserved IP**.

| Device  | Reserve IP  | MAC address         |
|---------|-------------|---------------------|
| Romulus | 10.0.0.172  | `7C-B5-66-43-20-4C` |
| Remoria | 10.0.0.182  | `70-15-FB-90-BD-CF` |
| Bubba   | 10.0.0.191  | `30-F6-EF-8B-D3-46` |
