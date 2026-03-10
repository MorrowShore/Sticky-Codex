<#
.SYNOPSIS
starts or reattaches a sticky Codex session on a remote Linux server.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 `
  -HostName "your.vps.host" `
  -UserName "youruser" `
  -RemoteProjectDir "/srv/project"

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 `
  -HostName "your.vps.host" `
  -UserName "youruser" `
  -AuthMode password `
  -RemoteProjectDir "/srv/project"
#>

param(
    [string]$HostAlias = "",
    [string]$HostName = "",
    [string]$UserName = "",
    [int]$Port = 22,
    [string]$IdentityFile = "",
    [string]$RemoteProjectDir = "",
    [string]$SessionName = "",
    [int]$IdleDays = 7,
    [int]$ReconnectDelaySeconds = 3,
    [switch]$NoSyncAuth,
    [string]$RemoteScript = "/usr/local/bin/codex-vps",
    [ValidateSet("auto", "key", "password")]
    [string]$AuthMode = "auto",
    [string]$Password = "",
    [string]$ProfileFile = $(Join-Path $env:LOCALAPPDATA "sticky-codex\connection.env"),
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$script:SshBackend = "openssh"

function Show-Banner {
    Write-Host "sticky-codex"
    Write-Host "AGPL-3.0-or-later"
    Write-Host "Morrow Shore https://morrowshore.com"
    Write-Host ""
}

function Show-Usage {
    @"
usage:
  powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 -HostName your.vps.host -UserName youruser -RemoteProjectDir /srv/project [options]

options:
  -HostAlias myvps
  -HostName your.vps.host
  -UserName youruser
  -Port 22
  -IdentityFile C:\Users\you\.ssh\id_ed25519
  -RemoteProjectDir /srv/project
  -SessionName codex-project
  -IdleDays 7
  -ReconnectDelaySeconds 3
  -AuthMode auto|key|password
  -Password yourpassword
  -ProfileFile C:\Users\you\AppData\Local\sticky-codex\connection.env
  -NoSyncAuth
  -RemoteScript /usr/local/bin/codex-vps

examples:
  powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 `
    -HostName "your.vps.host" `
    -UserName "youruser" `
    -RemoteProjectDir "/srv/project"

  powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 `
    -HostName "your.vps.host" `
    -UserName "youruser" `
    -AuthMode password `
    -RemoteProjectDir "/srv/project"

  powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 `
    -HostName "your.vps.host" `
    -UserName "youruser" `
    -Port 2222 `
    -IdentityFile "C:\Users\you\.ssh\id_ed25519" `
    -RemoteProjectDir "/srv/project"
"@ | Write-Host
}

function Get-SanitizedSessionName {
    param([string]$RemotePath)

    $leaf = Split-Path $RemotePath -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = "project"
    }

    $safe = ($leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "project"
    }

    return "codex-$safe"
}

function Read-ProfileMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path $Path)) {
        return $map
    }

    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $split = $trimmed.Split("=", 2)
        if ($split.Count -ne 2) {
            continue
        }

        $key = $split[0].Trim()
        $value = $split[1].Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $map[$key] = $value
        }
    }

    return $map
}

function Get-ProfileValue {
    param(
        [hashtable]$Map,
        [string]$Key,
        [string]$Fallback = ""
    )

    if ($Map.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($Map[$Key])) {
        return [string]$Map[$Key]
    }

    return $Fallback
}

function Decode-Base64 {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    try {
        $bytes = [Convert]::FromBase64String($Text)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return ""
    }
}

function Resolve-ProfileFile {
    if ($PSBoundParameters.ContainsKey("ProfileFile")) {
        return
    }

    if (Test-Path $script:ProfileFile) {
        return
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidates += (Join-Path $PSScriptRoot "connection.env")
    }
    $candidates += (Join-Path (Get-Location).Path "connection.env")

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $script:ProfileFile = $candidate
            return
        }
    }
}

function Prompt-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Default)) {
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }

        return $answer
    }

    return (Read-Host $Prompt)
}

function Prompt-Required {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )

    while ($true) {
        $value = Prompt-WithDefault -Prompt $Prompt -Default $Default
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host "value is required."
    }
}

function Load-ProfileValues {
    $profileMap = Read-ProfileMap -Path $script:ProfileFile

    if ([string]::IsNullOrWhiteSpace($script:HostAlias)) {
        $script:HostAlias = Get-ProfileValue -Map $profileMap -Key "HOST_ALIAS" -Fallback "myvps"
    }

    if ([string]::IsNullOrWhiteSpace($script:HostName)) {
        $script:HostName = Get-ProfileValue -Map $profileMap -Key "HOST_NAME"
    }

    if ([string]::IsNullOrWhiteSpace($script:UserName)) {
        $script:UserName = Get-ProfileValue -Map $profileMap -Key "USER_NAME"
    }

    if (-not $PSBoundParameters.ContainsKey("Port")) {
        $profilePort = Get-ProfileValue -Map $profileMap -Key "PORT"
        if (-not [string]::IsNullOrWhiteSpace($profilePort)) {
            try {
                $script:Port = [int]$profilePort
            } catch {
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:IdentityFile)) {
        $script:IdentityFile = Get-ProfileValue -Map $profileMap -Key "IDENTITY_FILE"
    }

    if ([string]::IsNullOrWhiteSpace($script:RemoteProjectDir)) {
        $script:RemoteProjectDir = Get-ProfileValue -Map $profileMap -Key "REMOTE_PROJECT_DIR"
    }

    if ([string]::IsNullOrWhiteSpace($script:SessionName)) {
        $script:SessionName = Get-ProfileValue -Map $profileMap -Key "SESSION_NAME"
    }

    if (-not $PSBoundParameters.ContainsKey("IdleDays")) {
        $profileIdle = Get-ProfileValue -Map $profileMap -Key "IDLE_DAYS"
        if (-not [string]::IsNullOrWhiteSpace($profileIdle)) {
            try {
                $script:IdleDays = [int]$profileIdle
            } catch {
            }
        }
    }

    if (-not $PSBoundParameters.ContainsKey("ReconnectDelaySeconds")) {
        $profileDelay = Get-ProfileValue -Map $profileMap -Key "RECONNECT_DELAY_SECONDS"
        if (-not [string]::IsNullOrWhiteSpace($profileDelay)) {
            try {
                $script:ReconnectDelaySeconds = [int]$profileDelay
            } catch {
            }
        }
    }

    if (-not $PSBoundParameters.ContainsKey("NoSyncAuth")) {
        $profileSync = Get-ProfileValue -Map $profileMap -Key "SYNC_AUTH"
        if ($profileSync -eq "0") {
            $script:NoSyncAuth = $true
        }
    }

    if (-not $PSBoundParameters.ContainsKey("RemoteScript")) {
        $script:RemoteScript = Get-ProfileValue -Map $profileMap -Key "REMOTE_SCRIPT" -Fallback "/usr/local/bin/codex-vps"
    }

    if (-not $PSBoundParameters.ContainsKey("AuthMode")) {
        $profileAuth = Get-ProfileValue -Map $profileMap -Key "AUTH_MODE" -Fallback "auto"
        if ($profileAuth -in @("auto", "key", "password")) {
            $script:AuthMode = $profileAuth
        }
    }

    if (-not $PSBoundParameters.ContainsKey("Password")) {
        $script:Password = Decode-Base64 (Get-ProfileValue -Map $profileMap -Key "PASSWORD_B64")
        if ([string]::IsNullOrWhiteSpace($script:Password)) {
            $script:Password = Get-ProfileValue -Map $profileMap -Key "PASSWORD"
        }
    }
}

function Ensure-RequiredConnectionValues {
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        $missing += "-HostName"
    }
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $missing += "-UserName"
    }
    if ([string]::IsNullOrWhiteSpace($RemoteProjectDir)) {
        $missing += "-RemoteProjectDir"
    }

    if ($missing.Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($script:HostAlias)) {
            $script:HostAlias = "myvps"
        }
        return
    }

    Write-Host "missing required remote connection value(s): $($missing -join ', ')"
    Write-Host "run quick-install again to populate $ProfileFile, or pass one-run overrides."
    exit 1
}

function Ensure-OverridesWhenProfileMissing {
    if (Test-Path $ProfileFile) {
        return
    }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        $missing += "-HostName"
    }
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $missing += "-UserName"
    }
    if ([string]::IsNullOrWhiteSpace($RemoteProjectDir)) {
        $missing += "-RemoteProjectDir"
    }

    if ($missing.Count -eq 0) {
        return
    }

    Write-Host "connection profile was not found:"
    Write-Host "  $ProfileFile"
    Write-Host ""
    Write-Host "when the profile is missing, pass one-run overrides:"
    Write-Host "  -HostName your.vps.host -UserName root -RemoteProjectDir /srv/project"
    Write-Host ""
    Write-Host "missing required override(s): $($missing -join ', ')"
    exit 1
}

function Ensure-WindowsOpenSsh {
    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    $scp = Get-Command scp -ErrorAction SilentlyContinue
    if ($ssh -and $scp) {
        return
    }

    Write-Host "OpenSSH client is missing. attempting to install it..."
    $capability = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Client*" } | Select-Object -First 1
    if (-not $capability) {
        throw "could not find the Windows OpenSSH client capability."
    }

    if ($capability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    }

    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    $scp = Get-Command scp -ErrorAction SilentlyContinue
    if (-not $ssh -or -not $scp) {
        throw "OpenSSH client installation did not make ssh and scp available."
    }
}

function Ensure-Codex {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        throw "codex cli is not installed or not in PATH on this Windows machine."
    }
}

function Select-SshBackend {
    if ($AuthMode -ne "password" -or [string]::IsNullOrWhiteSpace($Password)) {
        $script:SshBackend = "openssh"
        return
    }

    $plink = Get-Command plink -ErrorAction SilentlyContinue
    $pscp = Get-Command pscp -ErrorAction SilentlyContinue

    if ($plink -and $pscp) {
        $script:SshBackend = "putty"
        Write-Host "using plink/pscp backend for non-interactive password reconnects."
        return
    }

    $script:SshBackend = "openssh"
    Write-Host "password auth selected without plink/pscp; OpenSSH will prompt for password on reconnect."
}

function Get-LocalCodexAuthPath {
    if ($env:CODEX_HOME) {
        $candidate = Join-Path $env:CODEX_HOME "auth.json"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return (Join-Path $HOME ".codex\auth.json")
}

function Invoke-RemoteSsh {
    param(
        [string]$RemoteCommand,
        [switch]$Interactive
    )

    if ($script:SshBackend -eq "putty") {
        $args = @("-ssh", "-P", "$Port", "-l", $UserName)

        if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
            $args += @("-i", $IdentityFile)
        }

        if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
            $args += @("-pw", $Password)
        }

        if ($Interactive) {
            $args += @($HostName, $RemoteCommand)
            & plink @args
        } else {
            $args += @("-batch", $HostName, $RemoteCommand)
            & plink @args
        }

        return $LASTEXITCODE
    }

    $args = @("-F", $script:SshConfigPath)
    if ($Interactive) {
        $args += "-tt"
    }
    $args += @($HostAlias, $RemoteCommand)
    & ssh @args
    return $LASTEXITCODE
}

function Invoke-RemoteScp {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    if ($script:SshBackend -eq "putty") {
        $args = @("-P", "$Port", "-l", $UserName)

        if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
            $args += @("-i", $IdentityFile)
        }

        if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
            $args += @("-pw", $Password)
        }

        $args += @($LocalPath, "$HostName`:$RemotePath")
        & pscp @args
        return $LASTEXITCODE
    }

    & scp -F $script:SshConfigPath $LocalPath "$HostAlias`:$RemotePath"
    return $LASTEXITCODE
}

function Sync-LocalCodexAuthToRemote {
    $localAuth = Get-LocalCodexAuthPath

    if (-not (Test-Path $localAuth)) {
        throw @"
local Codex auth.json was not found at:
  $localAuth

do this on Windows first:
  1. ensure %USERPROFILE%\.codex\config.toml contains:
       cli_auth_credentials_store = "file"
  2. run:
       codex login
"@
    }

    Write-Host "syncing local Codex auth to VPS..."
    $prepareExit = Invoke-RemoteSsh -RemoteCommand "mkdir -p ~/.codex && chmod 700 ~/.codex"
    if ($prepareExit -ne 0) {
        throw "failed to prepare ~/.codex on the remote host."
    }

    $copyExit = Invoke-RemoteScp -LocalPath $localAuth -RemotePath "~/.codex/auth.json"
    if ($copyExit -ne 0) {
        throw "failed to copy auth.json to the remote host."
    }
}

function Quote-ForBashSingle {
    param([string]$Text)
    return "'" + ($Text -replace "'", "'""'""'") + "'"
}

function Write-TempSshConfig {
    $lines = @()
    $lines += "Host $HostAlias"
    $lines += "    HostName $HostName"
    $lines += "    User $UserName"
    $lines += "    Port $Port"
    $lines += "    ServerAliveInterval 30"
    $lines += "    ServerAliveCountMax 120"
    $lines += "    TCPKeepAlive yes"
    $lines += "    RequestTTY force"

    switch ($AuthMode) {
        "password" {
            $lines += "    PreferredAuthentications password,keyboard-interactive"
            $lines += "    PubkeyAuthentication no"
            $lines += "    IdentitiesOnly no"
        }
        "key" {
            if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
                $lines += "    IdentitiesOnly yes"
                $lines += "    IdentityFile $IdentityFile"
            } else {
                $lines += "    IdentitiesOnly no"
            }
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
                $lines += "    IdentityFile $IdentityFile"
            }
        }
    }

    Set-Content -Path $script:SshConfigPath -Value ($lines -join "`r`n")
}

function Start-ReconnectLoop {
    $projectArg = Quote-ForBashSingle $RemoteProjectDir
    $sessionArg = Quote-ForBashSingle $SessionName
    $launchCmd = "$RemoteScript --project-dir $projectArg --session-name $sessionArg --idle-days $IdleDays"
    $remoteCmd = "bash -lc " + (Quote-ForBashSingle $launchCmd)

    while ($true) {
        Write-Host ""
        Write-Host "connecting to $HostAlias | session=$SessionName | project=$RemoteProjectDir"
        [void](Invoke-RemoteSsh -Interactive -RemoteCommand $remoteCmd)

        Write-Host ""
        Write-Host "disconnected. reconnecting in $ReconnectDelaySeconds seconds..."
        Start-Sleep -Seconds $ReconnectDelaySeconds
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

Resolve-ProfileFile
Ensure-OverridesWhenProfileMissing
Load-ProfileValues
Ensure-RequiredConnectionValues

if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($UserName) -or [string]::IsNullOrWhiteSpace($RemoteProjectDir)) {
    Show-Usage
    exit 1
}

if ([string]::IsNullOrWhiteSpace($SessionName)) {
    $SessionName = Get-SanitizedSessionName -RemotePath $RemoteProjectDir
}

$TempDir = Join-Path $env:TEMP "codex-remote"
$null = New-Item -ItemType Directory -Force -Path $TempDir
$script:SshConfigPath = Join-Path $TempDir "ssh_config"

Show-Banner
Ensure-WindowsOpenSsh
Ensure-Codex
Write-TempSshConfig
Select-SshBackend

if (-not $NoSyncAuth) {
    Sync-LocalCodexAuthToRemote
}

Start-ReconnectLoop
