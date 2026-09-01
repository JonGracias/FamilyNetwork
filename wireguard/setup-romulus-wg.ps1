<#
.SYNOPSIS
  Bring Romulus up as a WireGuard client of the relay VPS, and open the local
  firewall to the tunnel. Run from an ADMIN terminal on Romulus.

.DESCRIPTION
  This is the HOME half of the relay. It dials OUT to the VPS, which is why it
  works through the double NAT with nothing forwarded on anyone's router.

  On first run it generates a keypair and stops, printing the PUBLIC key - add
  that to the VPS as a [Peer], then re-run with -VpsPublicKey to finish.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup-romulus-wg.ps1 -VpsEndpoint vps.datakiin.com:51820
  # ...add printed key to VPS, then:
  powershell -ExecutionPolicy Bypass -File .\setup-romulus-wg.ps1 -VpsEndpoint vps.datakiin.com:51820 -VpsPublicKey '<key>'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$VpsEndpoint,          # host:port of the VPS
  [string]$VpsPublicKey,                               # VPS server public key
  [string]$TunnelAddress = '10.8.0.2/24',              # this machine, inside the tunnel
  [string]$WgSubnet      = '10.8.0.0/24',
  [string]$ConfDir       = 'C:\ProgramData\WireGuard',
  [string]$TunnelName    = 'wg0'
)
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an Administrator terminal.'
}

# --- 1. WireGuard present? --------------------------------------------------
$wg = Get-Command wg.exe -EA SilentlyContinue
if (-not $wg) { $wg = Get-Item "$env:ProgramFiles\WireGuard\wg.exe" -EA SilentlyContinue }
if (-not $wg) {
  Write-Host 'Installing WireGuard (~15 MB)...' -ForegroundColor Cyan
  winget install --id WireGuard.WireGuard -e --silent --accept-package-agreements --accept-source-agreements
  $wg = Get-Item "$env:ProgramFiles\WireGuard\wg.exe" -EA SilentlyContinue
  if (-not $wg) { throw 'WireGuard did not install. Get it from https://www.wireguard.com/install/' }
} else { Write-Host 'WireGuard already installed.' -ForegroundColor Green }
if ($wg.PSObject.Properties['Source'] -and $wg.Source) { $wgExe = $wg.Source } else { $wgExe = $wg.FullName }
$wgQuick  = Join-Path (Split-Path $wgExe) 'wireguard.exe'

# --- 2. keypair (generate once, reuse forever) ------------------------------
New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
$keyFile = Join-Path $ConfDir "$TunnelName.privatekey"
if (-not (Test-Path $keyFile)) {
  Write-Host 'Generating keypair...' -ForegroundColor Cyan
  (& $wgExe genkey) | Set-Content $keyFile -NoNewline -Encoding ascii
  # private key readable only by SYSTEM+Administrators
  icacls $keyFile /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
}
$priv = (Get-Content $keyFile -Raw).Trim()
$pub  = ($priv | & $wgExe pubkey).Trim()

if (-not $VpsPublicKey) {
  Write-Host ''
  Write-Host '=== ROMULUS PUBLIC KEY - add this to the VPS, then re-run with -VpsPublicKey ===' -ForegroundColor Yellow
  Write-Host ''
  Write-Host "  $pub" -ForegroundColor White
  Write-Host ''
  Write-Host '  On the VPS, append to /etc/wireguard/wg0.conf:' -ForegroundColor Gray
  Write-Host ''
  Write-Host '    [Peer]'                                        -ForegroundColor Gray
  Write-Host "    PublicKey  = $pub"                             -ForegroundColor Gray
  Write-Host "    AllowedIPs = $($TunnelAddress.Split('/')[0])/32" -ForegroundColor Gray
  Write-Host ''
  Write-Host '    then: sudo systemctl restart wg-quick@wg0'     -ForegroundColor Gray
  Write-Host ''
  return
}

# --- 3. tunnel config -------------------------------------------------------
# AllowedIPs is deliberately the tunnel subnet ONLY, never 0.0.0.0/0: this box
# keeps using the house internet normally: the tunnel carries inbound service
# traffic, not everything. PersistentKeepalive is what holds the NAT mapping
# open through both layers of NAT so the VPS can reach back in.
$conf = @"
[Interface]
PrivateKey = $priv
Address    = $TunnelAddress

[Peer]
PublicKey           = $VpsPublicKey
Endpoint            = $VpsEndpoint
AllowedIPs          = $WgSubnet
PersistentKeepalive = 25
"@
$confPath = Join-Path $ConfDir "$TunnelName.conf"
Set-Content -Path $confPath -Value $conf -Encoding ascii
icacls $confPath /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
Write-Host "Wrote $confPath" -ForegroundColor Green

# --- 4. install as a service so it reconnects on boot -----------------------
$svc = Get-Service "WireGuardTunnel`$$TunnelName" -EA SilentlyContinue
if ($svc) {
  & $wgQuick /uninstalltunnelservice $TunnelName | Out-Null
  Start-Sleep -Seconds 2
}
& $wgQuick /installtunnelservice $confPath
Start-Sleep -Seconds 3
$svc = Get-Service "WireGuardTunnel`$$TunnelName" -EA SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') { Write-Host 'Tunnel service running.' -ForegroundColor Green }
else { Write-Warning 'Tunnel service is not running - check the WireGuard UI for the error.' }

# --- 5. firewall: THE step people miss --------------------------------------
# Existing FamilyNetwork rules are scoped to LocalSubnet (10.0.0.0/24). Traffic
# arriving through the tunnel is sourced from 10.8.0.1, which is NOT LocalSubnet,
# so those rules do not match and every forwarded connection dies silently.
# These rules re-open the same services specifically to the tunnel subnet.
$rules = @(
  @{ Name='FamilyNetwork - Minecraft Java (tunnel)';   Proto='TCP'; Port='25560-25579' }
  @{ Name='FamilyNetwork - Minecraft voice (tunnel)';  Proto='UDP'; Port='24450-24469' }
  @{ Name='FamilyNetwork - Geyser Bedrock (tunnel)';   Proto='UDP'; Port='19132'       }
  @{ Name='FamilyNetwork - SSH (tunnel)';              Proto='TCP'; Port='22'          }
)
foreach ($r in $rules) {
  Get-NetFirewallRule -DisplayName $r.Name -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
  New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
      -Protocol $r.Proto -LocalPort $r.Port -RemoteAddress $WgSubnet `
      -Profile Any -Group 'FamilyNetwork' | Out-Null
  Write-Host "  firewall: $($r.Name)  $($r.Proto)/$($r.Port) from $WgSubnet" -ForegroundColor Green
}
# Profile Any is correct here and is NOT a loosening: RemoteAddress pins these
# rules to the tunnel subnet, which is narrower than LocalSubnet ever was.

# --- 6. verify --------------------------------------------------------------
Write-Host ''
Write-Host '=== handshake ===' -ForegroundColor Cyan
Start-Sleep -Seconds 3
& $wgExe show $TunnelName
Write-Host ''
Write-Host 'A "latest handshake" line above means the tunnel is UP.' -ForegroundColor Gray
Write-Host "Test from the VPS:  ping $($TunnelAddress.Split('/')[0])" -ForegroundColor Gray
Write-Host 'Then from a phone on CELLULAR (wifi off):  nc -vz <vps-ip> 25569' -ForegroundColor Gray
