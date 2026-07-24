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
