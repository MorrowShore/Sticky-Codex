param(
    [string]$Target = $(Join-Path $env:LOCALAPPDATA "sticky-codex\codex-remote.ps1"),
    [string]$ProfileFile = $(Join-Path $env:LOCALAPPDATA "sticky-codex\connection.env")
)

$ErrorActionPreference = "Stop"
$repoOwner = "morrowshore"
$repoName = "sticky-codex"
$branches = @("main", "master")
$targetDir = Split-Path -Parent $Target
$targetWasExplicit = $PSBoundParameters.ContainsKey("Target")

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

        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
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

function Encode-Base64 {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
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

function Write-Rule {
    Write-Host "------------------------------------------------------------"
}

function Ensure-CodexConfigFileStoreLine {
    param([string]$ConfigPath)

    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path $configDir)) {
        $null = New-Item -ItemType Directory -Force -Path $configDir
    }

    $line = 'cli_auth_credentials_store = "file"'
    $existing = @()

    if (Test-Path $ConfigPath) {
        $existing = Get-Content -Path $ConfigPath
    }

    $filtered = @($existing | Where-Object { $_.Trim() -ne $line })
    $newContent = @($line) + $filtered
    $text = ($newContent -join "`r`n")
    if (-not [string]::IsNullOrEmpty($text)) {
        $text += "`r`n"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigPath, $text, $utf8NoBom)
}

function Start-CodexLoginWindow {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoExit", "-Command", "codex login") | Out-Null
}

function Offer-DesktopShortcut {
    param([string]$ScriptPath)

    $choice = (Prompt-WithDefault -Prompt "create desktop shortcut? (y/N)" -Default "N").ToLowerInvariant()
    if ($choice -notin @("y", "yes")) {
        return
    }

    $desktopPath = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($desktopPath) -or -not (Test-Path $desktopPath)) {
        Write-Host "desktop path was not found. skipped shortcut creation."
        return
    }

    $shortcutPath = Join-Path $desktopPath "sticky-codex.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$ScriptPath`""
    $shortcut.WorkingDirectory = (Split-Path -Parent $ScriptPath)
    $shortcut.IconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
    $shortcut.Description = "start sticky-codex reconnect launcher"
    $shortcut.Save()

    Write-Host "desktop shortcut created: $shortcutPath"
}

function Download-Launcher {
    param([string]$OutFile)

    foreach ($branch in $branches) {
        $uri = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/windows-client/codex-remote.ps1"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $OutFile
            return
        } catch {
        }
    }

    throw "failed to download windows-client/codex-remote.ps1 from main or master branch."
}

function Resolve-InstallTarget {
    if ($script:targetWasExplicit) {
        return
    }

    while ($true) {
        $choice = (Prompt-WithDefault -Prompt "install location (default/here)" -Default "default").ToLowerInvariant()
        switch ($choice) {
            "default" {
                return
            }
            "here" {
                $script:Target = Join-Path (Get-Location).Path "codex-remote.ps1"
                return
            }
            default {
                Write-Host "please enter default or here."
            }
        }
    }
}

function Write-ProfileFile {
    param(
        [string]$Path,
        [hashtable]$Values
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir
    }

    function Escape-EnvValue {
        param([string]$Value)

        if ($null -eq $Value) {
            return ""
        }

        return ($Value -replace '\\', '\\\\' -replace '"', '\"')
    }

    $lines = @(
        "# sticky-codex connection profile",
        ('HOST_ALIAS="{0}"' -f (Escape-EnvValue $Values.HOST_ALIAS)),
        ('HOST_NAME="{0}"' -f (Escape-EnvValue $Values.HOST_NAME)),
        ('USER_NAME="{0}"' -f (Escape-EnvValue $Values.USER_NAME)),
        ('PORT="{0}"' -f (Escape-EnvValue $Values.PORT)),
        ('IDENTITY_FILE="{0}"' -f (Escape-EnvValue $Values.IDENTITY_FILE)),
        ('REMOTE_PROJECT_DIR="{0}"' -f (Escape-EnvValue $Values.REMOTE_PROJECT_DIR)),
        ('SESSION_NAME="{0}"' -f (Escape-EnvValue $Values.SESSION_NAME)),
        ('IDLE_DAYS="{0}"' -f (Escape-EnvValue $Values.IDLE_DAYS)),
        ('RECONNECT_DELAY_SECONDS="{0}"' -f (Escape-EnvValue $Values.RECONNECT_DELAY_SECONDS)),
        ('SYNC_AUTH="{0}"' -f (Escape-EnvValue $Values.SYNC_AUTH)),
        ('REMOTE_SCRIPT="{0}"' -f (Escape-EnvValue $Values.REMOTE_SCRIPT)),
        ('AUTH_MODE="{0}"' -f (Escape-EnvValue $Values.AUTH_MODE)),
        ('PASSWORD_B64="{0}"' -f (Escape-EnvValue $Values.PASSWORD_B64)),
        'PASSWORD=""'
    )

    Set-Content -Path $Path -Value ($lines -join "`r`n")
}

Resolve-InstallTarget
$targetDir = Split-Path -Parent $Target
if (-not (Test-Path $targetDir)) {
    $null = New-Item -ItemType Directory -Force -Path $targetDir
}

Download-Launcher -OutFile $Target

Write-Host "downloaded $Target"
Write-Host ""

$profileMap = Read-ProfileMap -Path $ProfileFile
$syncAuth = Get-ProfileValue -Map $profileMap -Key "SYNC_AUTH" -Fallback "1"
$authSetupMode = "manual"
Write-Rule
Write-Host "remote connection setup"
Write-Rule
$hostAlias = Prompt-WithDefault -Prompt "host alias" -Default (Get-ProfileValue -Map $profileMap -Key "HOST_ALIAS" -Fallback "myvps")
$hostName = Prompt-Required -Prompt "remote host (ip or domain)" -Default (Get-ProfileValue -Map $profileMap -Key "HOST_NAME")
$userName = Prompt-Required -Prompt "remote user" -Default (Get-ProfileValue -Map $profileMap -Key "USER_NAME" -Fallback "root")
$port = Prompt-WithDefault -Prompt "ssh port" -Default (Get-ProfileValue -Map $profileMap -Key "PORT" -Fallback "22")
$remoteProjectDir = Prompt-Required -Prompt "remote project directory" -Default (Get-ProfileValue -Map $profileMap -Key "REMOTE_PROJECT_DIR")
$sessionName = Prompt-WithDefault -Prompt "session name (blank for auto)" -Default (Get-ProfileValue -Map $profileMap -Key "SESSION_NAME")
$idleDays = Prompt-WithDefault -Prompt "idle days before stale session cleanup" -Default (Get-ProfileValue -Map $profileMap -Key "IDLE_DAYS" -Fallback "7")
$reconnectDelay = Prompt-WithDefault -Prompt "reconnect delay seconds" -Default (Get-ProfileValue -Map $profileMap -Key "RECONNECT_DELAY_SECONDS" -Fallback "3")

$authModeDefault = (Get-ProfileValue -Map $profileMap -Key "AUTH_MODE" -Fallback "auto").ToLowerInvariant()
if ($authModeDefault -notin @("auto", "key", "password")) {
    $authModeDefault = "auto"
}

while ($true) {
    $authMode = (Prompt-WithDefault -Prompt "ssh auth mode (auto/key/password)" -Default $authModeDefault).ToLowerInvariant()
    if ($authMode -in @("auto", "key", "password")) {
        break
    }

    Write-Host "please enter auto, key, or password."
}

$identityFile = ""
if ($authMode -in @("auto", "key")) {
    $identityFile = Prompt-WithDefault -Prompt "ssh identity file path (optional)" -Default (Get-ProfileValue -Map $profileMap -Key "IDENTITY_FILE")
}

$existingPassword = Decode-Base64 (Get-ProfileValue -Map $profileMap -Key "PASSWORD_B64")
if ([string]::IsNullOrEmpty($existingPassword)) {
    $existingPassword = Get-ProfileValue -Map $profileMap -Key "PASSWORD"
}

$password = ""
if ($authMode -eq "password") {
    if (-not [string]::IsNullOrEmpty($existingPassword)) {
        $secure = Read-Host "ssh password (stored in profile) [previous password]" -AsSecureString
    } else {
        $secure = Read-Host "ssh password (stored in profile)" -AsSecureString
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ([string]::IsNullOrEmpty($password) -and -not [string]::IsNullOrEmpty($existingPassword)) {
        $password = $existingPassword
    }
}

$syncChoice = (Prompt-WithDefault -Prompt "sync local Codex auth.json before attach? (Y/n)" -Default "Y").ToLowerInvariant()
$syncAuth = if ($syncChoice -in @("n", "no")) { "0" } else { "1" }
if ($syncAuth -eq "1") {
    Write-Host "tip: choose manual if you have already done codex login setup."
    while ($true) {
        $authSetupMode = (Prompt-WithDefault -Prompt "auth setup mode (manual/auto)" -Default "manual").ToLowerInvariant()
        if ($authSetupMode -in @("manual", "auto")) {
            break
        }
        Write-Host "please enter manual or auto."
    }
}

$profileValues = @{
    HOST_ALIAS = $hostAlias
    HOST_NAME = $hostName
    USER_NAME = $userName
    PORT = $port
    IDENTITY_FILE = $identityFile
    REMOTE_PROJECT_DIR = $remoteProjectDir
    SESSION_NAME = $sessionName
    IDLE_DAYS = $idleDays
    RECONNECT_DELAY_SECONDS = $reconnectDelay
    SYNC_AUTH = $syncAuth
    REMOTE_SCRIPT = (Get-ProfileValue -Map $profileMap -Key "REMOTE_SCRIPT" -Fallback "/usr/local/bin/codex-vps")
    AUTH_MODE = $authMode
    PASSWORD_B64 = (Encode-Base64 $password)
}

Write-ProfileFile -Path $ProfileFile -Values $profileValues
Write-Host "saved connection profile: $ProfileFile"
Write-Host ""

Write-Rule
Write-Host "codex auth setup"
Write-Rule
$codexConfigPath = Join-Path $HOME ".codex\config.toml"
if ($syncAuth -eq "1" -and $authSetupMode -eq "auto") {
    Ensure-CodexConfigFileStoreLine -ConfigPath $codexConfigPath
    Start-CodexLoginWindow
    Write-Host "auto mode applied:"
    Write-Host "  - added cli_auth_credentials_store = ""file"" at the top of:"
    Write-Host "    $codexConfigPath"
    Write-Host "  - started codex login in a new PowerShell window"
    Write-Host ""
    Write-Host "setup is finished in this installer window."
    Write-Host "open the config file anytime with:"
    Write-Host "  notepad `"$codexConfigPath`""
    Write-Host ""
} elseif ($syncAuth -eq "1") {
    Write-Host "manual mode selected."
    Write-Host "put this in %USERPROFILE%\.codex\config.toml:"
    Write-Host ""
    Write-Host '```toml'
    Write-Host 'cli_auth_credentials_store = "file"'
    Write-Host '```'
    Write-Host ""
    Write-Host "then run:"
    Write-Host ""
    Write-Host "  codex login"
    Write-Host ""
    Write-Host "open the config file with:"
    Write-Host "  notepad `"$codexConfigPath`""
    Write-Host ""
    Write-Host "why: sticky-codex syncs auth.json to the remote server before attach, and Codex only writes auth.json when file-based auth storage is enabled."
    Write-Host ""
} else {
    Write-Host "sync of local auth.json is disabled in this profile."
    Write-Host "you can still run codex login later if needed."
    Write-Host ""
}

Write-Rule
Write-Host "desktop shortcut"
Write-Rule
Offer-DesktopShortcut -ScriptPath $Target
Write-Host ""

Write-Rule
Write-Host "how to run after setup"
Write-Rule
Write-Host "option 1 (direct command):"
Write-Host ""
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Target`""
Write-Host ""
Write-Host "option 2 (from install directory):"
Write-Host ""
Write-Host "  cd `"$targetDir`""
Write-Host "  powershell -ExecutionPolicy Bypass -File `".\codex-remote.ps1`""
Write-Host ""
Write-Host "one-run override command (flags win over profile):"
Write-Host ""
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Target`" -HostName `"your.vps.host`" -UserName `"root`" -RemoteProjectDir `"/srv/project`""
Write-Host ""
Write-Host "note: if $ProfileFile is missing later, overrides are required (-HostName, -UserName, -RemoteProjectDir)."
Write-Rule
