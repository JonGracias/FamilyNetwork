# watch-remoria-disk.ps1 — runs ON ROMULUS (scheduled weekly): polls Remoria's
# D: Seagate over SSH for the UDMA CRC counter (SMART 199) and last-7-days
# Event 153 / dirty-boot counts. Appends to logs\remoria-disk-watch.csv and
# writes an ALERT file to the desktop if CRC climbs above the previous reading
# (post-SATA-fix baseline: 2,336 on 2026-07-28).
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $repo 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir | Out-Null }
$csv = Join-Path $logDir 'remoria-disk-watch.csv'
if (-not (Test-Path $csv)) { Set-Content $csv 'date,crc199,event153_7d,dirtyBoots_7d' }

$remote = @'
$ErrorActionPreference = "SilentlyContinue"
$d = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_ATAPISmartData | Where-Object InstanceName -match "ST2000DM008"
$v = $d.VendorSpecific
$crc = [uint64]0
for ($i = 2; $i -lt 362; $i += 12) {
  if ($v[$i] -eq 199) { for ($j = 5; $j -le 10; $j++) { $crc += [uint64]$v[$i+$j] -shl (8*($j-5)) } }
}
$e153 = @(Get-WinEvent -FilterHashtable @{LogName="System"; ProviderName="disk"; Id=153; StartTime=(Get-Date).AddDays(-7)}).Count
$e41  = @(Get-WinEvent -FilterHashtable @{LogName="System"; ProviderName="Microsoft-Windows-Kernel-Power"; Id=41; StartTime=(Get-Date).AddDays(-7)}).Count
"$crc,$e153,$e41"
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
$out = ssh -o ConnectTimeout=15 -o BatchMode=yes remoria "powershell -NoProfile -EncodedCommand $b64" 2>$null |
       Where-Object { $_ -match '^\d+,\d+,\d+$' } | Select-Object -First 1

$today = Get-Date -Format 'yyyy-MM-dd'
if (-not $out) {
    Add-Content $csv "$today,UNREACHABLE,,"
    exit 0
}

$prev = (Import-Csv $csv | Where-Object crc199 -match '^\d+$' | Select-Object -Last 1).crc199
Add-Content $csv "$today,$out"

$crcNow = [uint64]($out -split ',')[0]
if ($prev -and $crcNow -gt [uint64]$prev) {
    $alert = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ALERT-remoria-disk.txt'
    @(
        "Remoria D: (Seagate ST2000DM008) CRC errors are climbing again."
        "Previous: $prev   Now: $crcNow   ($today)"
        "The SATA cable/connector problem is NOT fixed. Details: $csv"
        "Full picture: run diag-disk.ps1 on Remoria (see FamilyNetwork README)."
    ) | Set-Content $alert
}
