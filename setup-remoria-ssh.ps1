# One-time SSH server setup for Remoria
# Run this in an ADMINISTRATOR PowerShell window on Remoria.
# Right-click Start > "Terminal (Admin)" then:  powershell -ExecutionPolicy Bypass -File .\setup-remoria-ssh.ps1

$ErrorActionPreference = 'Stop'

# Public key of Romulus (jon@romulus) - grants Romulus passwordless SSH access
$romulusKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGfo0QKJDgkiGTmNtbwUyMfyjqocb5PV613W0Sd+LrHN jon@romulus'

Write-Host "[1/5] Installing OpenSSH Server..." -ForegroundColor Cyan
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null

Write-Host "[2/5] Starting sshd and setting it to start automatically..." -ForegroundColor Cyan
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

Write-Host "[3/5] Opening firewall port 22 (private network)..." -ForegroundColor Cyan
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Private | Out-Null
}

Write-Host "[4/5] Authorizing Romulus's SSH key..." -ForegroundColor Cyan
# For admin users, Windows sshd reads this file instead of ~\.ssh\authorized_keys
$adminKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content -Path $adminKeys -Value $romulusKey
icacls $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

# Also add to the per-user location in case this account is not an admin
$userSsh = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path $userSsh)) { New-Item -ItemType Directory $userSsh | Out-Null }
Add-Content -Path (Join-Path $userSsh 'authorized_keys') -Value $romulusKey

Write-Host "[5/5] Setting PowerShell as the default SSH shell..." -ForegroundColor Cyan
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

Write-Host ""
Write-Host "DONE. Summary for Romulus:" -ForegroundColor Green
$edition = (Get-ComputerInfo -Property WindowsProductName).WindowsProductName
"  Windows edition : $edition  (RDP hosting requires Pro)"
"  Username        : $env:USERNAME"
"  IP addresses    : " + ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notmatch '^127|^169'} | ForEach-Object IPAddress) -join ', ')
"  sshd status     : " + (Get-Service sshd).Status
