# setup-jose-labserver-access.ps1
# ---------------------------------------------------------------------------
# Sets up SSH access to the Datakiin lab server from a Windows PC.
#
# Run this ON JOSE'S PC. No admin rights needed. Safe to run more than once.
#
#   Right-click this file -> "Run with PowerShell"
#   (or, in a PowerShell window:)
#   powershell -ExecutionPolicy Bypass -File setup-jose-labserver-access.ps1
#
# What it does:
#   - makes an SSH keypair in your user folder
#   - writes an SSH shortcut so you can just type: ssh labserver
#   - checks whether Tailscale is installed and signed in
#   - opens an email addressed to Jon containing the PUBLIC half of the key
#
# WHAT IT NEVER DOES: your PRIVATE key never leaves this computer. The thing it
# emails is the public half, which is safe to send in plain text - it is the
# lock, not the key. Nothing is uploaded anywhere. No passwords are asked for.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$JonEmail    = 'jon.gracias@gmail.com'
$ServerUser  = 'jose'
$ServerAddr  = '100.86.218.41'                    # labserver, Tailscale address
$ServerFqdn  = 'labserver.tail663992.ts.net'      # same box, MagicDNS name
$Alias       = 'labserver'

$SshDir      = Join-Path $env:USERPROFILE '.ssh'
$KeyPath     = Join-Path $SshDir 'id_ed25519_labserver'
$PubPath     = "$KeyPath.pub"
$ConfigPath  = Join-Path $SshDir 'config'
$DesktopCopy = Join-Path ([Environment]::GetFolderPath('Desktop')) 'labserver-publickey.txt'

function Say($msg)  { Write-Host $msg }
function Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }
function Good($msg) { Write-Host "OK $msg" -ForegroundColor Green }

Say "==========================================================="
Say " Lab server access setup"
Say " Makes a key for you and emails the public half to Jon."
Say "==========================================================="

# --- 1. Is the SSH client even here? ---------------------------------------
Step "Checking for the Windows SSH client"
$keygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $keygen) {
    Warn "ssh-keygen was not found on this PC."
    Say  ""
    Say  "Windows 10 and 11 include it, but it can be switched off. To turn it on:"
    Say  "   Settings > System > Optional features > Add an optional feature"
    Say  "   search for 'OpenSSH Client', install it, then run this script again."
    Say  ""
    Say  "(That step asks for an administrator password. If you do not have one,"
    Say  " tell Jon and he will sort it out.)"
    Read-Host "Press Enter to close"
    exit 1
}
Good "found at $($keygen.Source)"

# --- 2. Make the keypair ----------------------------------------------------
Step "Setting up your key"
if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    Say "created $SshDir"
}

$q = [char]34   # a double-quote character, for building cmd.exe command lines

if (Test-Path $PubPath) {
    Good "you already have a key for the lab server - reusing it, not making a new one"
} else {
    $comment = "$ServerUser@$env:COMPUTERNAME"
    # NOTE: invoked through cmd deliberately. PowerShell 5.1 silently DROPS an
    # empty '' argument, so -N '' becomes "no passphrase argument at all" and
    # ssh-keygen sits at an interactive prompt forever. cmd passes "" through
    # correctly on both PowerShell 5.1 and 7.
    cmd /c "ssh-keygen -t ed25519 -f $q$KeyPath$q -N $q$q -C $q$comment$q" | Out-Null
    if (-not (Test-Path $PubPath)) {
        Warn "Key generation did not produce $PubPath."
        Warn "Send Jon a screenshot of this window."
        Read-Host "Press Enter to close"
        exit 1
    }
    Good "new key created"
}

# Prove the private key reads back with no passphrase on it. If this fails the
# key cannot be used for a hands-off login, and it is better to know now than
# at the first ssh attempt.
cmd /c "ssh-keygen -y -P $q$q -f $q$KeyPath$q" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Warn "The key exists but could not be read back without a passphrase."
    Warn "Delete these two files and re-run this script:"
    Warn "   $KeyPath"
    Warn "   $PubPath"
    Read-Host "Press Enter to close"
    exit 1
}
Good "key verified"

$PubKey = (Get-Content $PubPath -Raw).Trim()

# --- 3. SSH shortcut so 'ssh labserver' just works ---------------------------
Step "Writing the SSH shortcut"
$block = @"

Host $Alias
    HostName $ServerAddr
    User $ServerUser
    IdentityFile $KeyPath
    IdentitiesOnly yes
    # Same machine by name, if the address above ever stops working:
    #   HostName $ServerFqdn
"@

if (Test-Path $ConfigPath) {
    $existing = Get-Content $ConfigPath -Raw
    if ($existing -match "(?m)^\s*Host\s+$Alias\s*$") {
        Good "'$Alias' shortcut is already in your SSH config - left alone"
    } else {
        Copy-Item $ConfigPath "$ConfigPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Add-Content -Path $ConfigPath -Value $block -Encoding ascii
        Good "added '$Alias' to your SSH config (old file backed up)"
    }
} else {
    Set-Content -Path $ConfigPath -Value $block.TrimStart() -Encoding ascii
    Good "created your SSH config with the '$Alias' shortcut"
}

# --- 4. Tailscale ------------------------------------------------------------
Step "Checking Tailscale (the private network the server sits on)"
$tsExe   = 'C:\Program Files\Tailscale\tailscale.exe'
$tsLogin = $null
if (Test-Path $tsExe) {
    Good "Tailscale is installed"
    try {
        $st = & $tsExe status --json 2>$null | ConvertFrom-Json
        if ($st.BackendState -eq 'Running') {
            Good "Tailscale is signed in and running"
            $tsLogin = $st.User."$($st.Self.UserID)".LoginName
            if ($tsLogin) { Say "   signed in as: $tsLogin" }
        } else {
            Warn "Tailscale is installed but not signed in (state: $($st.BackendState))."
            Warn "Open Tailscale from the system tray, sign in, then re-run this script."
        }
    } catch {
        Warn "Could not read Tailscale status. Open it from the system tray and check it is signed in."
    }
} else {
    Warn "Tailscale is NOT installed. You will need it to reach the server."
    Say  ""
    Say  "Install it one of two ways:"
    Say  "   - in a PowerShell window:   winget install Tailscale.Tailscale"
    Say  "   - or download it from:      https://tailscale.com/download/windows"
    Say  ""
    Say  "Sign in, then run this script again. It is fine to finish the email step"
    Say  "below first - Jon can be getting your key installed in the meantime."
}

# --- 5. Hand the public key back to Jon --------------------------------------
Step "Sending your public key to Jon"

$tsReport = if ($tsLogin) { $tsLogin } else { '(not signed in yet)' }
$bodyLines = @(
    "Hi Jon - here is my public key for the lab server.",
    "",
    "Computer            : $env:COMPUTERNAME",
    "Windows user        : $env:USERNAME",
    "Server login wanted : $ServerUser",
    "Tailscale account   : $tsReport",
    "",
    "----- public key, one line -----",
    $PubKey,
    "--------------------------------",
    "",
    "Sent by setup-jose-labserver-access.ps1"
)
$body = $bodyLines -join "`r`n"

# Always leave the key somewhere reachable by hand BEFORE trying mailto. Plenty
# of people read mail in a browser with no mailto handler registered, in which
# case Start-Process does nothing visible and looks like the script hung.
Set-Content -Path $DesktopCopy -Value $body -Encoding ascii
Good "saved a copy to your Desktop: labserver-publickey.txt"
try {
    Set-Clipboard -Value $PubKey
    Good "copied the key to your clipboard (Ctrl+V pastes it)"
} catch {
    Warn "Could not copy to clipboard - use the Desktop file instead."
}

$subject = "Lab server public key - $env:COMPUTERNAME"
$mailto  = "mailto:$JonEmail" +
           "?subject=" + [uri]::EscapeDataString($subject) +
           "&body="    + [uri]::EscapeDataString($body)

$opened = $false
try {
    Start-Process $mailto
    $opened = $true
} catch {
    $opened = $false
}

Say ""
Say "==========================================================="
if ($opened) {
    Say " An email to $JonEmail should have opened."
    Say " Check that it appeared, then press Send."
    Say ""
    Say " If NO email window opened, this PC has no mail app set up."
    Say " No problem - the key is already on your clipboard. Just email"
    Say " $JonEmail yourself and paste it in."
} else {
    Say " Could not open an email automatically."
    Say " The key is on your clipboard and saved on your Desktop as"
    Say " labserver-publickey.txt - please email it to $JonEmail"
}
Say "==========================================================="
Say ""
Say "Your public key (safe to share):"
Say ""
Say $PubKey
Say ""
Say "NEXT: once Jon says your key is installed, open PowerShell and type:"
Say ""
Say "    ssh $Alias"
Say ""
Say "The first time it will ask 'Are you sure you want to continue connecting?'."
Say "Check with Jon that the fingerprint shown matches, then type: yes"
Say ""
Read-Host "Press Enter to close"
