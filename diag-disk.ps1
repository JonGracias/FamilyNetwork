# diag-disk.ps1 — read-only storage deep-dive: dirty shutdowns, disk-error history,
# and SMART raw attributes ("Healthy" status hides these; the raw counters tell the
# real story — 199 CRC = cable, 191 G-sense = shock, 5/197 = failing media).
# Run locally, or from Romulus over SSH with -EncodedCommand (see README).
$ErrorActionPreference = 'SilentlyContinue'

Write-Output '=== DISK -> DRIVE LETTER MAP ==='
Get-Disk | ForEach-Object { Write-Output ("Disk " + $_.Number + ": " + $_.FriendlyName + " (" + [math]::Round($_.Size/1GB) + " GB)") }
Get-Partition | Where-Object DriveLetter | ForEach-Object { Write-Output ("  Disk " + $_.DiskNumber + " -> " + $_.DriveLetter + ":") }

Write-Output ''
Write-Output '=== PHYSICAL DISK HEALTH ==='
Get-PhysicalDisk | ForEach-Object {
  $c = $_ | Get-StorageReliabilityCounter
  Write-Output ($_.FriendlyName + "  " + $_.MediaType + "  Health: " + $_.HealthStatus + "  Temp: " + $c.Temperature + "C  PowerOnHours: " + $c.PowerOnHours)
}

Write-Output ''
Write-Output '=== SMART RAW ATTRIBUTES ==='
$smart = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_ATAPISmartData
$names = @{
  1='Raw Read Error Rate'; 5='Reallocated Sectors'; 7='Seek Error Rate'; 9='Power-On Hours';
  10='Spin Retry Count'; 12='Power Cycle Count'; 184='End-to-End Error'; 187='Reported Uncorrectable';
  188='Command Timeout'; 189='High Fly Writes'; 190='Airflow Temp'; 191='G-Sense (shock) Errors';
  192='Power-Off Retract (unsafe shutdowns)'; 193='Load Cycle Count'; 194='Temperature';
  197='Current Pending Sectors'; 198='Offline Uncorrectable'; 199='UDMA CRC Errors (cable)'; 240='Head Flying Hours'
}
foreach ($d in $smart) {
  Write-Output ("--- " + $d.InstanceName + " ---")
  $v = $d.VendorSpecific
  for ($i = 2; $i -lt 362; $i += 12) {
    $id = $v[$i]
    if ($id -eq 0) { continue }
    $raw = [uint64]0
    for ($j = 5; $j -le 10; $j++) { $raw += [uint64]$v[$i+$j] -shl (8*($j-5)) }
    $label = if ($names.ContainsKey([int]$id)) { $names[[int]$id] } else { "attr $id" }
    Write-Output ("  {0,3}  {1,-38} raw={2}" -f $id, $label, $raw)
  }
}

Write-Output ''
Write-Output '=== DIRTY SHUTDOWNS (Kernel-Power 41, last 14 days) ==='
# BugcheckCode=0 + PowerButtonTimestamp=0 -> power loss or hard freeze;
# BugcheckCode=0 + timestamp set -> power button held; BugcheckCode!=0 -> BSOD.
$boots = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; StartTime=(Get-Date).AddDays(-14)}
if ($boots) {
  foreach ($b in $boots) {
    $x = [xml]$b.ToXml(); $d = @{}
    $x.Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
    Write-Output ("{0}  BugcheckCode={1}  PowerButtonTimestamp={2}" -f $b.TimeCreated, $d['BugcheckCode'], $d['PowerButtonTimestamp'])
  }
} else { Write-Output 'None' }

Write-Output ''
Write-Output '=== DISK ERROR HISTORY (Event 153 IO-retried, weekly, full log) ==='
$all153 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk'; Id=153} -MaxEvents 5000
if ($all153) {
  Write-Output ("Total in log: " + $all153.Count + "  |  Oldest: " + ($all153 | Select-Object -Last 1).TimeCreated + "  |  Newest: " + $all153[0].TimeCreated)
  $all153 | Group-Object { $_.TimeCreated.ToString('yyyy-MM') + ' wk' + [int]([math]::Floor(($_.TimeCreated.Day-1)/7)+1) } | Sort-Object Name | ForEach-Object {
    Write-Output ("  " + $_.Name + ": " + $_.Count)
  }
} else { Write-Output 'None found' }

Write-Output ''
Write-Output '=== NTFS FLUSH FAILURES (Event 140, last 14 days) ==='
$ntfs = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Ntfs'; Id=140; StartTime=(Get-Date).AddDays(-14)}
if ($ntfs) { Write-Output ("Total: " + $ntfs.Count + " — corruption risk on the named volume; check which drive") } else { Write-Output 'None' }

Write-Output ''
Write-Output '=== STORAHCI LINK RESETS (Event 129) ==='
$r = Get-WinEvent -FilterHashtable @{LogName='System'; Id=129} -MaxEvents 500 | Where-Object { $_.ProviderName -match 'storahci|stornvme' }
if ($r) { Write-Output ("Total: " + $r.Count + "  |  Newest: " + $r[0].TimeCreated) } else { Write-Output 'None found' }
