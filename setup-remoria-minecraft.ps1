# setup-remoria-minecraft.ps1 — prep Remoria for Minecraft test-server hosting.
# Installs Eclipse Temurin JDK 21 (from adoptium.net) if Java 21+ isn't present,
# and opens TCP 25565 inbound — Private profile, LAN addresses only.
# Idempotent; run from an admin terminal:
#   powershell -ExecutionPolicy Bypass -File .\setup-remoria-minecraft.ps1
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Output 'ERROR: must run as Administrator.'; exit 1 }

# --- Java 21 ---
$needJava = $true
$java = Get-Command java -ErrorAction SilentlyContinue
if ($java) {
    $verLine = (cmd /c "java -version 2>&1" | Select-Object -First 1)
    if ($verLine -match '"(\d+)') {
        $major = [int]$Matches[1]
        Write-Output "Found Java $major at $($java.Source)"
        if ($major -ge 21) { $needJava = $false }
    }
}

if ($needJava) {
    $msi = Join-Path $env:TEMP 'temurin21.msi'
    Write-Output 'Downloading Temurin JDK 21 MSI from api.adoptium.net ...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest 'https://api.adoptium.net/v3/installer/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse' -OutFile $msi
    Write-Output ("Downloaded " + [math]::Round((Get-Item $msi).Length/1MB) + " MB. Installing (silent) ...")
    # FeatureEnvironment adds java to system PATH; FeatureJavaHome sets JAVA_HOME.
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Output "ERROR: msiexec exit code $($p.ExitCode)"; exit 1 }
    Remove-Item $msi -Force
    Write-Output 'Java installed.'
} else {
    Write-Output 'Java 21+ already present — skipping install.'
}

# --- Firewall: TCP 25565, Private profile, LAN only ---
$ruleName = 'Minecraft Server (TCP 25565)'
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Write-Output "Firewall rule '$ruleName' already exists — skipping."
} else {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 25565 -Profile Private -RemoteAddress LocalSubnet | Out-Null
    Write-Output "Firewall rule '$ruleName' created (Private profile, LocalSubnet only)."
}

# --- Summary ---
Write-Output ''
Write-Output '=== SUMMARY ==='
$javaNow = (Get-Command java -ErrorAction SilentlyContinue).Source
if (-not $javaNow) { $javaNow = "$env:ProgramFiles\Eclipse Adoptium (new shell needed for PATH)" }
Write-Output ("Java:     " + $javaNow)
cmd /c "`"$env:ProgramFiles\Eclipse Adoptium\jdk-21*\bin\java.exe`" -version 2>&1" | Select-Object -First 1 | ForEach-Object { Write-Output ("Version:  " + $_) }
Get-NetFirewallRule -DisplayName $ruleName | ForEach-Object { Write-Output ("Firewall: " + $_.DisplayName + " [" + $_.Profile + ", enabled=" + $_.Enabled + "]") }
