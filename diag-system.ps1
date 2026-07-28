# diag-system.ps1 — read-only general health check for any machine on the network.
# Run locally, or from Romulus over SSH (see README "Diagnostics" — use -EncodedCommand,
# piping to `powershell -Command -` mangles multi-line scripts).
$ErrorActionPreference = 'SilentlyContinue'

Write-Output '=== OS / UPTIME ==='
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ("OS:      " + $os.Caption + " (build " + $os.BuildNumber + ")")
Write-Output ("Booted:  " + $os.LastBootUpTime + "  (uptime " + ((Get-Date) - $os.LastBootUpTime).ToString('d\d\ h\h\ m\m') + ")")

Write-Output ''
Write-Output '=== CPU ==='
$cpu = Get-CimInstance Win32_Processor
Write-Output ("CPU:     " + $cpu.Name)
Write-Output ("Cores:   " + $cpu.NumberOfCores + " physical / " + $cpu.NumberOfLogicalProcessors + " logical")
Write-Output ("Load:    " + $cpu.LoadPercentage + "%")

Write-Output ''
Write-Output '=== MEMORY ==='
$totalGB = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
$freeGB  = [math]::Round($os.FreePhysicalMemory/1MB, 1)
Write-Output ("RAM:     $totalGB GB total, $freeGB GB free, " + [math]::Round($totalGB-$freeGB,1) + " GB in use")

Write-Output ''
Write-Output '=== DISKS ==='
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  $sz = [math]::Round($_.Size/1GB,1); $fr = [math]::Round($_.FreeSpace/1GB,1)
  Write-Output ("Drive " + $_.DeviceID + "  " + $sz + " GB total, " + $fr + " GB free (" + [math]::Round(100*$_.FreeSpace/$_.Size) + "% free)")
}

Write-Output ''
Write-Output '=== JAVA ==='
$java = Get-Command java -ErrorAction SilentlyContinue
if ($java) {
  Write-Output ("java found at: " + $java.Source)
  cmd /c "java -version 2>&1" | ForEach-Object { Write-Output $_ }
} else {
  Write-Output 'java NOT found on PATH'
}

Write-Output ''
Write-Output '=== NETWORK ==='
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } | ForEach-Object {
  Write-Output ($_.InterfaceAlias + ": " + $_.IPAddress + "/" + $_.PrefixLength)
}
$prof = Get-NetConnectionProfile
Write-Output ("Profile: " + $prof.Name + " -> " + $prof.NetworkCategory)

Write-Output ''
Write-Output '=== FIREWALL (enabled inbound-allow rules of interest) ==='
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow |
  Where-Object { $_.DisplayName -match 'ssh|minecraft|java|25565' } |
  ForEach-Object { Write-Output ($_.DisplayName + "  [profile: " + $_.Profile + "]") }

Write-Output ''
Write-Output '=== SSH SERVICE ==='
Get-Service sshd | ForEach-Object { Write-Output ("sshd: " + $_.Status + " (startup: " + $_.StartType + ")") }

Write-Output ''
Write-Output '=== POWER PLAN / SLEEP ==='
powercfg /getactivescheme
$acSleep = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Current AC Power Setting'
Write-Output ("Sleep on AC (0=never): " + ($acSleep -replace '.*:\s*',''))

Write-Output ''
Write-Output '=== RECENT SYSTEM ERRORS (last 7 days, by source) ==='
$errs = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 200
if ($errs) {
  $errs | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
    Write-Output ($_.Count.ToString().PadLeft(4) + "x  " + $_.Name)
  }
} else { Write-Output 'No critical/error events in the last 7 days' }

Write-Output ''
Write-Output '=== PENDING REBOOT? ==='
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
Write-Output ("Reboot pending: " + $pending)
