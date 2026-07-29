# setup-ssh-harden.ps1 — disable SSH password authentication (key auth only).
# Machine-agnostic; run on any box AFTER key-based login is proven working.
# Backs up sshd_config, prepends PasswordAuthentication no (OpenSSH takes the
# first value seen, and the top of the file is safely outside any Match block),
# restarts sshd. Idempotent.
$ErrorActionPreference = 'Stop'

$cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
if (-not (Test-Path $cfg)) { Write-Output "ERROR: $cfg not found — is OpenSSH Server installed?"; exit 1 }

# KbdInteractiveAuthentication must go too: on Windows OpenSSH it is the
# password prompt most clients actually use.
$want = @('PasswordAuthentication no', 'KbdInteractiveAuthentication no')
$lines = @(Get-Content $cfg) | Where-Object { $_ -notin $want }
if (@(Get-Content $cfg -TotalCount 2 | Where-Object { $_ -in $want }).Count -eq 2) {
    Write-Output 'Already hardened. Nothing to do.'
} else {
    $bak = "$cfg.bak"
    if (-not (Test-Path $bak)) { Copy-Item $cfg $bak; Write-Output "Backed up config to $bak" }
    Set-Content $cfg -Value ($want + $lines)
    Restart-Service sshd
    Write-Output 'Password + keyboard-interactive auth disabled; sshd restarted.'
}
Write-Output ("sshd: " + (Get-Service sshd).Status)
