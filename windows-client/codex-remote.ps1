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
    [int]$ReconnectDelaySeconds = 1,
    [switch]$NoSyncAuth,
    [string]$RemoteScript = "/usr/local/bin/codex-vps",
    [ValidateSet("auto", "key", "password")]
    [string]$AuthMode = "auto",
    [string]$Password = "",
    [ValidateSet("no", "socks5", "http", "quic", "wss")]
    [string]$ProxyType = "no",
    [string]$ProxySpec = "",
    [string]$QuicServer = "",
    [int]$QuicPort = 61313,
    [string]$QuicPassword = "",
    [string]$QuicSni = "",
    [int]$QuicLocalSocksPort = 10809,
    [ValidateSet("no", "socks5", "http")]
    [string]$QuicUpstreamType = "no",
    [string]$QuicUpstreamSpec = "",
    [string]$ProfileFile = $(Join-Path $env:LOCALAPPDATA "sticky-codex\connection.env"),
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$script:SshBackend = "openssh"
$script:PlinkExe = "plink"
$script:PscpExe = "pscp"
$script:NcatExe = "ncat"
$script:SingBoxExe = "sing-box"
$script:QuicRunner = $null
$script:TunnelSshHost = ""
$script:PuttyHostKeyPins = @()
$script:LastRemoteSshExitCode = 0
$script:CliBoundParams = @{}
foreach ($k in $PSBoundParameters.Keys) {
    $script:CliBoundParams[$k] = $true
}

function Configure-ConsoleUtf8 {
    if (-not [Environment]::UserInteractive) {
        return
    }

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [Console]::InputEncoding = $utf8
        [Console]::OutputEncoding = $utf8
        $global:OutputEncoding = $utf8
    } catch {
    }
}

function Show-Banner {
    Write-Host "Sticky Codex"
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
  -ReconnectDelaySeconds 1
  -AuthMode auto|key|password
  -Password yourpassword
  -ProxyType no|socks5|http|wss
    (legacy alias: quic -> wss)
  -ProxySpec 127.0.0.1:8080[:username:password]
  -QuicServer your.vps.host
  -QuicPort 61313
  -QuicPassword yourquicpassword
  -QuicSni your.vps.host
  -QuicLocalSocksPort 10809
  -QuicUpstreamType no|socks5|http
  -QuicUpstreamSpec 127.0.0.1:8080[:username:password]
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

function Encode-Base64 {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Invoke-WithRetry {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [int]$Attempts = 5,
        [int]$BaseDelaySeconds = 4
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            & $Action
            return $true
        } catch {
            if ($attempt -ge $Attempts) {
                Write-Host "$Label failed after $Attempts attempts."
                return $false
            }

            $delay = [Math]::Min(30, $BaseDelaySeconds * $attempt)
            Write-Host "$Label failed (attempt $attempt/$Attempts). retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
        }
    }

    return $false
}

function Get-TextTail {
    param(
        [string]$Text,
        [int]$MaxLines = 12
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $lines = $Text -split "(`r`n|`n|`r)"
    $trimmed = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($trimmed.Count -le $MaxLines) {
        return ($trimmed -join " | ")
    }

    $tail = $trimmed[($trimmed.Count - $MaxLines)..($trimmed.Count - 1)]
    return ($tail -join " | ")
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $stdoutPath = Join-Path $env:TEMP ("codex-native-out-" + [Guid]::NewGuid().ToString("N") + ".log")
    $stderrPath = Join-Path $env:TEMP ("codex-native-err-" + [Guid]::NewGuid().ToString("N") + ".log")
    $oldNativePreference = $null
    $hasNativePreference = $false
    $oldErrorAction = $ErrorActionPreference

    try {
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
            $hasNativePreference = $true
            $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
            $global:PSNativeCommandUseErrorActionPreference = $false
        }
        $ErrorActionPreference = "Continue"

        & $FilePath @Arguments 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE

        $output = ""
        if (Test-Path $stdoutPath) {
            $output += (Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path $stderrPath) {
            $stderr = Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                if ([string]::IsNullOrWhiteSpace($output)) {
                    $output = $stderr
                } else {
                    $output = ($output.TrimEnd() + [Environment]::NewLine + $stderr).Trim()
                }
            }
        }
        return @{
            ExitCode = $exitCode
            Output = $output
        }
    } catch {
        $msg = ""
        if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
            $msg = $_.Exception.Message
        } else {
            $msg = ($_ | Out-String).Trim()
        }
        $nativeExit = 0
        try {
            $nativeExit = [int]$LASTEXITCODE
        } catch {
            $nativeExit = 0
        }
        return @{
            ExitCode = $(if ($nativeExit -gt 0) { $nativeExit } else { 1 })
            Output = $msg
        }
    } finally {
        if ($hasNativePreference) {
            $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
        $ErrorActionPreference = $oldErrorAction
        Remove-Item -Force -ErrorAction SilentlyContinue $stdoutPath, $stderrPath
    }
}

function Classify-WingetFailure {
    param(
        [string]$Output,
        [int]$ExitCode
    )

    $text = ""
    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        $text = $Output.ToLowerInvariant()
    }

    if ($text -match "no internet|internet connection|timed out|timeout|unable to connect|could not connect|could not resolve|name resolution|connection reset|connection refused|network") {
        return @{
            Kind = "network"
            Summary = "likely unstable internet/proxy/DNS path to winget sources."
        }
    }

    if ($text -match "group policy|administrator has blocked|disabled by policy|access is denied|permission denied|elevation|required") {
        return @{
            Kind = "policy-or-permission"
            Summary = "winget appears blocked by policy or insufficient permissions."
        }
    }

    if ($text -match "app installer|winget.exe|not recognized|not found") {
        return @{
            Kind = "winget-unavailable"
            Summary = "winget/App Installer is missing or not usable on this system."
        }
    }

    if ($text -match "source|msstore|agreement|hash does not match|installer hash") {
        return @{
            Kind = "winget-source"
            Summary = "winget source/index/package retrieval failed."
        }
    }

    if ($text -match "no package found matching input criteria|no package found") {
        return @{
            Kind = "package-not-found"
            Summary = "requested package ID was not found in current winget sources."
        }
    }

    return @{
        Kind = "unknown"
        Summary = "winget failed for an unknown reason."
    }
}

function Invoke-WingetInstallWithRetry {
    param(
        [string]$PackageId,
        [int]$Attempts = 4,
        [int]$BaseDelaySeconds = 10
    )

    $lastOutput = ""
    $lastExitCode = 0
    $lastDiag = @{
        Kind = "unknown"
        Summary = "winget failed for an unknown reason."
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $output = (& winget install --id $PackageId -e --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return @{
                Success = $true
                ExitCode = 0
                Kind = "ok"
                Summary = "winget completed successfully."
                Tail = (Get-TextTail -Text $output -MaxLines 12)
            }
        }

        $lastOutput = $output
        $lastExitCode = $exitCode
        $lastDiag = Classify-WingetFailure -Output $output -ExitCode $exitCode

        if ($lastDiag.Kind -eq "package-not-found") {
            break
        }

        if ($attempt -lt $Attempts) {
            $delay = [Math]::Min(30, $BaseDelaySeconds * $attempt)
            Write-Host "winget install $PackageId failed (attempt $attempt/$Attempts). cause=$($lastDiag.Kind). retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
        }
    }

    return @{
        Success = $false
        ExitCode = $lastExitCode
        Kind = $lastDiag.Kind
        Summary = $lastDiag.Summary
        Tail = (Get-TextTail -Text $lastOutput -MaxLines 12)
    }
}

function Escape-ProfileValue {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ($Value -replace '\\', '\\\\' -replace '"', '\"')
}

function Write-ProfileFile {
    param([string]$Path)

    $profileDir = Split-Path -Parent $Path
    if (-not (Test-Path $profileDir)) {
        $null = New-Item -ItemType Directory -Force -Path $profileDir
    }

    $lines = @(
        "# sticky-codex connection profile",
        ('HOST_ALIAS="{0}"' -f (Escape-ProfileValue $script:HostAlias)),
        ('HOST_NAME="{0}"' -f (Escape-ProfileValue $script:HostName)),
        ('USER_NAME="{0}"' -f (Escape-ProfileValue $script:UserName)),
        ('PORT="{0}"' -f (Escape-ProfileValue "$script:Port")),
        ('IDENTITY_FILE="{0}"' -f (Escape-ProfileValue $script:IdentityFile)),
        ('REMOTE_PROJECT_DIR="{0}"' -f (Escape-ProfileValue $script:RemoteProjectDir)),
        ('SESSION_NAME="{0}"' -f (Escape-ProfileValue $script:SessionName)),
        ('IDLE_DAYS="{0}"' -f (Escape-ProfileValue "$script:IdleDays")),
        ('RECONNECT_DELAY_SECONDS="{0}"' -f (Escape-ProfileValue "$script:ReconnectDelaySeconds")),
        ('SYNC_AUTH="{0}"' -f (Escape-ProfileValue $(if ($script:NoSyncAuth) { "0" } else { "1" }))),
        ('REMOTE_SCRIPT="{0}"' -f (Escape-ProfileValue $script:RemoteScript)),
        ('AUTH_MODE="{0}"' -f (Escape-ProfileValue $script:AuthMode)),
        ('PASSWORD_B64="{0}"' -f (Escape-ProfileValue (Encode-Base64 $script:Password))),
        ('PROXY_TYPE="{0}"' -f (Escape-ProfileValue $script:ProxyType)),
        ('PROXY_SPEC="{0}"' -f (Escape-ProfileValue $script:ProxySpec)),
        ('QUIC_SERVER="{0}"' -f (Escape-ProfileValue $script:QuicServer)),
        ('QUIC_PORT="{0}"' -f (Escape-ProfileValue "$script:QuicPort")),
        ('QUIC_PASSWORD_B64="{0}"' -f (Escape-ProfileValue (Encode-Base64 $script:QuicPassword))),
        ('QUIC_SNI="{0}"' -f (Escape-ProfileValue $script:QuicSni)),
        ('QUIC_LOCAL_SOCKS_PORT="{0}"' -f (Escape-ProfileValue "$script:QuicLocalSocksPort")),
        ('QUIC_UPSTREAM_TYPE="{0}"' -f (Escape-ProfileValue $script:QuicUpstreamType)),
        ('QUIC_UPSTREAM_SPEC="{0}"' -f (Escape-ProfileValue $script:QuicUpstreamSpec)),
        'PASSWORD=""'
    )

    Set-Content -Path $Path -Value ($lines -join "`r`n")
}

function Parse-ProxySpec {
    param([string]$Spec)

    $parts = $Spec.Split(":")
    if ($parts.Count -ne 2 -and $parts.Count -ne 4) {
        throw "invalid proxy spec. expected host:port or host:port:username:password"
    }

    $proxyHost = $parts[0].Trim()
    $proxyPort = $parts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($proxyHost) -or [string]::IsNullOrWhiteSpace($proxyPort)) {
        throw "invalid proxy spec. host and port are required."
    }

    $proxyUser = ""
    $proxyPassword = ""
    if ($parts.Count -eq 4) {
        $proxyUser = $parts[2]
        $proxyPassword = $parts[3]
    }

    return @{
        Host = $proxyHost
        Port = $proxyPort
        Username = $proxyUser
        Password = $proxyPassword
    }
}

function Build-NcatProxyCommand {
    param(
        [string]$TargetHostToken,
        [string]$TargetPortToken
    )

    if ($script:ProxyType -eq "no" -or [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
        return ""
    }

    if (-not (Resolve-NcatExe)) {
        throw "proxy mode requires ncat in PATH."
    }

    $proxy = Parse-ProxySpec -Spec $script:ProxySpec
    $type = if ($script:ProxyType -eq "socks5") { "socks5" } else { "http" }
    Normalize-NcatExePath
    $ncatCmd = $script:NcatExe
    if ($script:SshBackend -eq "putty") {
        # PuTTY proxycmd parsing treats backslash escapes (for example \n),
        # which breaks normal Windows paths like ...\Nmap\ncat.exe.
        $ncatCmd = $ncatCmd -replace '\\', '/'
        if ($ncatCmd -match "\s") {
            throw "ncat path '$ncatCmd' still contains spaces; unable to build a reliable PuTTY proxy command."
        }
    } elseif ($ncatCmd -match "\s") {
        $ncatCmd = '"' + ($ncatCmd -replace '"', '\"') + '"'
    }

    $cmd = "$ncatCmd --proxy $($proxy.Host):$($proxy.Port) --proxy-type $type"
    if ($script:SshBackend -ne "putty") {
        $cmd += " --no-shutdown"
    }
    if (-not [string]::IsNullOrWhiteSpace($proxy.Username)) {
        $cmd += " --proxy-auth $($proxy.Username):$($proxy.Password)"
    }
    $cmd += " $TargetHostToken $TargetPortToken"

    return $cmd
}

function Get-ShortWindowsPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $Path
    }

    $arg = '/d /c for %I in ("' + $Path + '") do @echo %~sI'
    $out = (& cmd.exe $arg 2>$null | Select-Object -First 1)
    $short = [string]$out
    if ([string]::IsNullOrWhiteSpace($short)) {
        return $Path
    }
    return $short.Trim().Trim('"')
}

function Normalize-NcatExePath {
    if ([string]::IsNullOrWhiteSpace($script:NcatExe)) {
        return
    }

    if ($script:SshBackend -eq "putty") {
        # Keep ncat in its original install directory so required DLLs resolve.
        $short = Get-ShortWindowsPath -Path $script:NcatExe
        if (-not [string]::IsNullOrWhiteSpace($short) -and $short -notmatch "\s") {
            $script:NcatExe = $short
            return
        }

        if ($script:NcatExe -match "\s") {
            # Some systems disable 8.3 names. Copy ncat + sibling DLLs to a stable
            # path without spaces so PuTTY -proxycmd can execute it reliably.
            $srcDir = Split-Path -Parent $script:NcatExe
            $leaf = Split-Path -Leaf $script:NcatExe
            $destDir = Join-Path $env:LOCALAPPDATA "sticky-codex\tools\ncat-runtime"
            $null = New-Item -ItemType Directory -Force -Path $destDir
            Copy-Item -Path (Join-Path $srcDir "*") -Destination $destDir -Recurse -Force
            $destExe = Join-Path $destDir $leaf
            if (Test-Path $destExe) {
                $script:NcatExe = $destExe
            }
        }
    }

    if ($script:NcatExe -match "\s") {
        return
    }
}

function Resolve-NcatExe {
    $ncat = Get-Command ncat -ErrorAction SilentlyContinue
    if ($ncat) {
        $script:NcatExe = $ncat.Source
        Normalize-NcatExePath
        return $true
    }

    foreach ($candidate in @(
        "$env:ProgramFiles\Nmap\ncat.exe",
        "${env:ProgramFiles(x86)}\Nmap\ncat.exe",
        (Join-Path $env:LOCALAPPDATA "sticky-codex\tools\nmap-portable\ncat.exe")
    )) {
        if (Test-Path $candidate) {
            $script:NcatExe = $candidate
            Normalize-NcatExePath
            return $true
        }
    }

    $wingetPkgRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkgRoot) {
        foreach ($pkgPrefix in @("Insecure.Nmap*", "Nmap.Nmap*")) {
            foreach ($pkgDir in Get-ChildItem -Path $wingetPkgRoot -Directory -Filter $pkgPrefix -ErrorAction SilentlyContinue) {
                $found = Get-ChildItem -Path $pkgDir.FullName -Filter "ncat.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) {
                    $script:NcatExe = $found.FullName
                    Normalize-NcatExePath
                    return $true
                }
            }
        }
    }

    return $false
}

function Download-NcatPortable {
    $toolDir = Join-Path $env:LOCALAPPDATA "sticky-codex\tools"
    $null = New-Item -ItemType Directory -Force -Path $toolDir

    $index = ""
    $gotIndex = Invoke-WithRetry -Label "fetch nmap dist index" -Attempts 5 -BaseDelaySeconds 6 -Action {
        $index = (& curl.exe -fsSL "https://nmap.org/dist/" 2>$null | Out-String)
        if ([string]::IsNullOrWhiteSpace($index)) {
            throw "empty nmap dist index response"
        }
    }
    if (-not $gotIndex -or [string]::IsNullOrWhiteSpace($index)) {
        return $false
    }

    $matches = [regex]::Matches($index, 'nmap-[0-9A-Za-z\.\-]+-win32\.zip')
    if ($matches.Count -eq 0) {
        return $false
    }

    $assetName = $matches[0].Value
    $assetUrl = "https://nmap.org/dist/$assetName"
    $zipPath = Join-Path $toolDir "nmap-portable.zip"
    $extractDir = Join-Path $toolDir "nmap-portable-extract"
    if (Test-Path $extractDir) {
        Remove-Item -Recurse -Force $extractDir
    }

    $downloaded = Invoke-WithRetry -Label "download nmap portable package" -Attempts 6 -BaseDelaySeconds 6 -Action {
        & curl.exe -fL $assetUrl -o $zipPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipPath)) {
            throw "failed to download $assetUrl"
        }
    }
    if (-not $downloaded) {
        return $false
    }

    try {
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    } catch {
        return $false
    }

    $ncatFile = Get-ChildItem -Path $extractDir -Filter "ncat.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ncatFile) {
        return $false
    }

    $srcDir = Split-Path -Parent $ncatFile.FullName
    $destDir = Join-Path $toolDir "nmap-portable"
    if (Test-Path $destDir) {
        Remove-Item -Recurse -Force $destDir
    }
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -Path (Join-Path $srcDir "*") -Destination $destDir -Recurse -Force
    $dest = Join-Path $destDir "ncat.exe"
    if (-not (Test-Path $dest)) {
        return $false
    }
    $script:NcatExe = $dest
    return $true
}

function Ensure-NcatForProxy {
    if ($script:ProxyType -eq "no" -or [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
        return
    }

    if (Resolve-NcatExe) {
        return
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    $wingetResult = $null
    if ($winget) {
        $nmapIds = @("Insecure.Nmap", "Nmap.Nmap")
        foreach ($pkgId in $nmapIds) {
            Write-Host "proxy mode requires ncat. attempting install via winget package '$pkgId'..."
            $wingetResult = Invoke-WingetInstallWithRetry -PackageId $pkgId -Attempts 6 -BaseDelaySeconds 10
            if ($wingetResult.Success) {
                break
            }

            Write-Host "winget install $pkgId failed."
            Write-Host "diagnosis: $($wingetResult.Summary) (kind=$($wingetResult.Kind), exit=$($wingetResult.ExitCode))"
            if (-not [string]::IsNullOrWhiteSpace($wingetResult.Tail)) {
                Write-Host "winget output tail: $($wingetResult.Tail)"
            }

            if ($wingetResult.Kind -eq "package-not-found") {
                continue
            }
        }
    }

    if (-not (Resolve-NcatExe)) {
        Write-Host "ncat was not found after winget attempts. trying portable download from nmap.org..."
        if (Download-NcatPortable -and (Resolve-NcatExe)) {
            return
        }
        if (-not $winget) {
            throw "proxy mode requires ncat, and winget is not available on this machine. install Nmap (ncat) manually, then retry."
        }

        if ($wingetResult -and -not $wingetResult.Success) {
            throw "proxy mode requires ncat. auto-install failed due to $($wingetResult.Kind): $($wingetResult.Summary)"
        }

        if ($wingetResult -and $wingetResult.Success) {
            $extra = ""
            if (-not [string]::IsNullOrWhiteSpace($wingetResult.Tail)) {
                $extra = " winget output tail: $($wingetResult.Tail)"
            }
            throw "proxy mode requires ncat. winget reported success, but ncat.exe was not found in PATH, Program Files\\Nmap, Program Files (x86)\\Nmap, or %LOCALAPPDATA%\\Microsoft\\WinGet\\Packages.$extra"
        }

        throw "proxy mode requires ncat. install Nmap (ncat), then retry."
    }
}

function Resolve-SingBoxExe {
    $cmd = Get-Command sing-box -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:SingBoxExe = $cmd.Source
        return $true
    }

    $candidate = Join-Path $env:LOCALAPPDATA "sticky-codex\tools\sing-box.exe"
    if (Test-Path $candidate) {
        $script:SingBoxExe = $candidate
        return $true
    }

    return $false
}

function Download-SingBoxPortable {
    $toolDir = Join-Path $env:LOCALAPPDATA "sticky-codex\tools"
    $null = New-Item -ItemType Directory -Force -Path $toolDir

    $arch = "amd64"
    if ($env:PROCESSOR_ARCHITECTURE -match "ARM64") {
        $arch = "arm64"
    }

    $release = $null
    $ok = Invoke-WithRetry -Label "fetch sing-box release metadata" -Attempts 5 -BaseDelaySeconds 5 -Action {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/SagerNet/sing-box/releases/latest" -TimeoutSec 90
        if (-not $release) {
            throw "empty release metadata"
        }
    }
    if (-not $ok -or -not $release) {
        return $false
    }

    $asset = $release.assets | Where-Object { $_.name -match "windows-$arch\.zip$" } | Select-Object -First 1
    if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -match "windows-amd64\.zip$" } | Select-Object -First 1
    }
    if (-not $asset) {
        return $false
    }

    $zipPath = Join-Path $toolDir "sing-box.zip"
    $extractDir = Join-Path $toolDir "sing-box-extract"
    if (Test-Path $extractDir) {
        Remove-Item -Recurse -Force $extractDir
    }

    $downloaded = Invoke-WithRetry -Label "download sing-box package" -Attempts 6 -BaseDelaySeconds 5 -Action {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -TimeoutSec 180
        if (-not (Test-Path $zipPath)) {
            throw "sing-box download did not produce a file"
        }
    }
    if (-not $downloaded) {
        return $false
    }

    try {
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    } catch {
        return $false
    }

    $exe = Get-ChildItem -Path $extractDir -Filter "sing-box.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) {
        return $false
    }

    $dest = Join-Path $toolDir "sing-box.exe"
    Copy-Item -Force $exe.FullName $dest
    $script:SingBoxExe = $dest
    return $true
}

function Ensure-SingBox {
    if (Resolve-SingBoxExe) {
        return
    }

    if ([Environment]::UserInteractive) {
        $choice = (Prompt-WithDefault -Prompt "stability core (sing-box) is missing on this client. install now? (Y/n)" -Default "Y").ToLowerInvariant()
        if ($choice -in @("n", "no")) {
            throw "stability mode requires sing-box on this client. install was skipped by user."
        }
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        foreach ($pkgId in @("SagerNet.sing-box", "sing-box.sing-box")) {
            $wingetResult = Invoke-WingetInstallWithRetry -PackageId $pkgId -Attempts 5 -BaseDelaySeconds 8
            if (Resolve-SingBoxExe) {
                return
            }
            if ($wingetResult.Kind -eq "package-not-found") {
                continue
            }
        }
    }

    if (Download-SingBoxPortable -and (Resolve-SingBoxExe)) {
        return
    }

    throw "stability mode requires sing-box, but it could not be installed automatically."
}

function Test-TcpPort {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 1200
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar) | Out-Null
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-AvailableLocalSocksPort {
    param(
        [int]$PreferredPort,
        [int]$SearchWindow = 200
    )

    if ($PreferredPort -lt 1 -or $PreferredPort -gt 65535) {
        $PreferredPort = 10809
    }

    if (-not (Test-TcpPort -TargetHost "127.0.0.1" -Port $PreferredPort -TimeoutMs 500)) {
        return $PreferredPort
    }

    $start = [Math]::Min(65535, $PreferredPort + 1)
    $end = [Math]::Min(65535, $PreferredPort + $SearchWindow)
    for ($p = $start; $p -le $end; $p++) {
        if (-not (Test-TcpPort -TargetHost "127.0.0.1" -Port $p -TimeoutMs 500)) {
            return $p
        }
    }

    throw "could not find a free local socks port near $PreferredPort for stability tunnel."
}

function Get-SshTargetHost {
    if (-not [string]::IsNullOrWhiteSpace($script:TunnelSshHost)) {
        return $script:TunnelSshHost
    }
    return $HostName
}

function Ensure-QuicLocalProxy {
    if ($script:ProxyType -ne "quic") {
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:QuicServer)) {
        $script:QuicServer = $HostName
    }
    if ([string]::IsNullOrWhiteSpace($script:QuicSni)) {
        $script:QuicSni = $script:QuicServer
    }

    Ensure-SingBox

    if (Test-TcpPort -TargetHost "127.0.0.1" -Port $script:QuicLocalSocksPort -TimeoutMs 900) {
        $nextPort = Get-AvailableLocalSocksPort -PreferredPort $script:QuicLocalSocksPort
        Write-Host "local port $script:QuicLocalSocksPort is already in use; quic tunnel will use $nextPort."
        $script:QuicLocalSocksPort = $nextPort
    }

    $tmpDir = Join-Path $env:TEMP "codex-remote"
    $null = New-Item -ItemType Directory -Force -Path $tmpDir
    $quicCfg = Join-Path $tmpDir "singbox-quic-client.json"

    $cfg = @{
        log = @{ level = "warn" }
        inbounds = @(
            @{
                type = "socks"
                listen = "127.0.0.1"
                listen_port = $script:QuicLocalSocksPort
            }
        )
        outbounds = @()
        route = @{ final = "hy2-out" }
    }

    $hy2Outbound = @{
        type = "hysteria2"
        tag = "hy2-out"
        server = $script:QuicServer
        server_port = $script:QuicPort
        password = $script:QuicPassword
        tls = @{
            enabled = $true
            server_name = $script:QuicSni
            insecure = $true
        }
    }

    $quicUpstreamType = $script:QuicUpstreamType.ToLowerInvariant()
    if ($quicUpstreamType -in @("socks5", "http")) {
        if ([string]::IsNullOrWhiteSpace($script:QuicUpstreamSpec)) {
            throw "quic upstream proxy is enabled but QUIC_UPSTREAM_SPEC is empty."
        }

        $upstream = Parse-ProxySpec -Spec $script:QuicUpstreamSpec
        $upstreamOutbound = @{
            type = if ($quicUpstreamType -eq "socks5") { "socks" } else { "http" }
            tag = "quic-upstream"
            server = $upstream.Host
            server_port = [int]$upstream.Port
        }

        if (-not [string]::IsNullOrWhiteSpace($upstream.Username)) {
            $upstreamOutbound.username = $upstream.Username
            $upstreamOutbound.password = $upstream.Password
        }

        $cfg.outbounds += $upstreamOutbound
        $hy2Outbound.detour = "quic-upstream"
    }

    $cfg.outbounds += $hy2Outbound

    Set-Content -Path $quicCfg -Value ($cfg | ConvertTo-Json -Depth 12)

    $proc = Start-Process -FilePath $script:SingBoxExe -ArgumentList @("run", "-c", $quicCfg) -WindowStyle Hidden -PassThru
    $script:QuicRunner = $proc

    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-TcpPort -TargetHost "127.0.0.1" -Port $script:QuicLocalSocksPort -TimeoutMs 600) {
            $script:ProxyType = "socks5"
            $script:ProxySpec = "127.0.0.1:$script:QuicLocalSocksPort"
            return
        }
        if ($proc.HasExited) {
            break
        }
    }

    throw "failed to start local QUIC proxy client (sing-box)."
}

function Ensure-WssLocalProxy {
    if ($script:ProxyType -ne "wss") {
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:QuicServer)) {
        $script:QuicServer = $HostName
    }
    if ([string]::IsNullOrWhiteSpace($script:QuicSni)) {
        $script:QuicSni = $script:QuicServer
    }
    if ($script:QuicPort -le 0) {
        $script:QuicPort = 13131
    }
    if ([string]::IsNullOrWhiteSpace($script:QuicPassword)) {
        throw "wss stability mode requires WSS password."
    }

    Ensure-SingBox

    if (Test-TcpPort -TargetHost "127.0.0.1" -Port $script:QuicLocalSocksPort -TimeoutMs 900) {
        $nextPort = Get-AvailableLocalSocksPort -PreferredPort $script:QuicLocalSocksPort
        Write-Host "local port $script:QuicLocalSocksPort is already in use; wss tunnel will use $nextPort."
        $script:QuicLocalSocksPort = $nextPort
    }

    $tmpDir = Join-Path $env:TEMP "codex-remote"
    $null = New-Item -ItemType Directory -Force -Path $tmpDir
    $wssCfg = Join-Path $tmpDir "singbox-wss-client.json"

    $cfg = @{
        log = @{ level = "warn" }
        inbounds = @(
            @{
                type = "socks"
                listen = "127.0.0.1"
                listen_port = $script:QuicLocalSocksPort
            }
        )
        outbounds = @()
        route = @{ final = "wss-out" }
    }

    $wssOutbound = @{
        type = "trojan"
        tag = "wss-out"
        server = $script:QuicServer
        server_port = $script:QuicPort
        password = $script:QuicPassword
        tls = @{
            enabled = $true
            server_name = $script:QuicSni
            insecure = $true
        }
        transport = @{
            type = "ws"
            path = "/sticky-codex"
        }
    }

    $wssUpstreamType = $script:QuicUpstreamType.ToLowerInvariant()
    if ($wssUpstreamType -in @("socks5", "http")) {
        if ([string]::IsNullOrWhiteSpace($script:QuicUpstreamSpec)) {
            throw "wss upstream proxy is enabled but QUIC_UPSTREAM_SPEC is empty."
        }

        $upstream = Parse-ProxySpec -Spec $script:QuicUpstreamSpec
        $upstreamOutbound = @{
            type = if ($wssUpstreamType -eq "socks5") { "socks" } else { "http" }
            tag = "wss-upstream"
            server = $upstream.Host
            server_port = [int]$upstream.Port
        }

        if (-not [string]::IsNullOrWhiteSpace($upstream.Username)) {
            $upstreamOutbound.username = $upstream.Username
            $upstreamOutbound.password = $upstream.Password
        }

        $cfg.outbounds += $upstreamOutbound
        $wssOutbound.detour = "wss-upstream"
    }

    $cfg.outbounds += $wssOutbound

    Set-Content -Path $wssCfg -Value ($cfg | ConvertTo-Json -Depth 12)

    $proc = Start-Process -FilePath $script:SingBoxExe -ArgumentList @("run", "-c", $wssCfg) -WindowStyle Hidden -PassThru
    $script:QuicRunner = $proc

    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-TcpPort -TargetHost "127.0.0.1" -Port $script:QuicLocalSocksPort -TimeoutMs 600) {
            $script:ProxyType = "socks5"
            $script:ProxySpec = "127.0.0.1:$script:QuicLocalSocksPort"
            return
        }
        if ($proc.HasExited) {
            break
        }
    }

    throw "failed to start local wss stability tunnel client (sing-box)."
}

function Get-PuttyProxyArgs {
    if ($script:ProxyType -eq "no" -or [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
        return @()
    }

    return @("-proxycmd", (Build-NcatProxyCommand -TargetHostToken "%host" -TargetPortToken "%port"))
}

function Get-Sha256PinsFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $pins = @()
    $seen = @{}
    $matches = [regex]::Matches($Text, "SHA256:[A-Za-z0-9+/=]+")
    foreach ($match in $matches) {
        $pin = [string]$match.Value
        if (-not [string]::IsNullOrWhiteSpace($pin) -and -not $seen.ContainsKey($pin)) {
            $seen[$pin] = $true
            $pins += $pin
        }
    }

    return $pins
}

function Resolve-PuttyHostKeyPins {
    param([string]$TargetHost)

    $pins = @()
    $sshKeyscan = Get-Command ssh-keyscan -ErrorAction SilentlyContinue
    $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if ($sshKeyscan -and $sshKeygen) {
        $scanPath = Join-Path $env:TEMP ("codex-hostkeys-" + [Guid]::NewGuid().ToString("N") + ".tmp")
        try {
            $scanOut = (& $sshKeyscan.Source "-p" "$Port" "-T" "8" $TargetHost 2>$null | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($scanOut)) {
                Set-Content -Path $scanPath -Value $scanOut
                $fingerprintOut = (& $sshKeygen.Source "-lf" $scanPath "-E" "sha256" 2>$null | Out-String)
                $pins = Get-Sha256PinsFromText -Text $fingerprintOut
            }
        } catch {
        } finally {
            Remove-Item -Force -ErrorAction SilentlyContinue $scanPath
        }
    }

    if ($pins.Count -gt 0) {
        return $pins
    }

    foreach ($mode in @("direct", "proxy")) {
        if ($mode -eq "proxy" -and ($script:ProxyType -eq "no" -or [string]::IsNullOrWhiteSpace($script:ProxySpec))) {
            continue
        }

        $sshProbeArgs = @(
            "-vv",
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "$Port"
        )
        if ($mode -eq "proxy") {
            $sshProbeArgs += @("-o", "ProxyCommand=$(Build-NcatProxyCommand -TargetHostToken '%h' -TargetPortToken '%p')")
        }
        $sshProbeArgs += @("$UserName@$TargetHost", "exit")

        $sshProbe = Invoke-NativeCapture -FilePath "ssh" -Arguments $sshProbeArgs
        $pins = Get-Sha256PinsFromText -Text ([string]$sshProbe.Output)
        if ($pins.Count -gt 0) {
            return $pins
        }
    }

    foreach ($mode in @("direct", "proxy")) {
        if ($mode -eq "proxy" -and ($script:ProxyType -eq "no" -or [string]::IsNullOrWhiteSpace($script:ProxySpec))) {
            continue
        }

        $probeArgs = @("-ssh", "-batch", "-v", "-P", "$Port", "-l", $UserName)
        if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
            $probeArgs += @("-i", $IdentityFile)
        }
        if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
            $probeArgs += @("-pw", $Password)
        }
        if ($mode -eq "proxy") {
            $probeArgs += Get-PuttyProxyArgs
        }
        $probeArgs += @($TargetHost, "true")

        $probe = Invoke-NativeCapture -FilePath $script:PlinkExe -Arguments $probeArgs
        $pins = Get-Sha256PinsFromText -Text ([string]$probe.Output)
        if ($pins.Count -gt 0) {
            return $pins
        }
    }

    return @()
}

function Get-PuttyHostKeyArgs {
    if ($script:SshBackend -ne "putty") {
        return @()
    }

    if ($null -eq $script:PuttyHostKeyPins -or $script:PuttyHostKeyPins.Count -eq 0) {
        return @()
    }

    $args = @()
    foreach ($pin in $script:PuttyHostKeyPins) {
        if (-not [string]::IsNullOrWhiteSpace($pin)) {
            $args += @("-hostkey", $pin)
        }
    }
    return $args
}

function Resolve-PuttyToolsFromKnownLocations {
    $plink = Get-Command plink -ErrorAction SilentlyContinue
    $pscp = Get-Command pscp -ErrorAction SilentlyContinue

    $known = @(
        "$env:ProgramFiles\PuTTY\plink.exe",
        "${env:ProgramFiles(x86)}\PuTTY\plink.exe",
        (Join-Path $env:LOCALAPPDATA "sticky-codex\tools\plink.exe")
    )
    if (-not $plink) {
        foreach ($candidate in $known) {
            if (Test-Path $candidate) {
                $plink = @{ Source = $candidate }
                break
            }
        }
    }

    $known = @(
        "$env:ProgramFiles\PuTTY\pscp.exe",
        "${env:ProgramFiles(x86)}\PuTTY\pscp.exe",
        (Join-Path $env:LOCALAPPDATA "sticky-codex\tools\pscp.exe")
    )
    if (-not $pscp) {
        foreach ($candidate in $known) {
            if (Test-Path $candidate) {
                $pscp = @{ Source = $candidate }
                break
            }
        }
    }

    if ($plink -and $pscp) {
        $script:PlinkExe = $plink.Source
        $script:PscpExe = $pscp.Source
        return $true
    }

    return $false
}

function Download-PuttyPortableTools {
    $toolDir = Join-Path $env:LOCALAPPDATA "sticky-codex\tools"
    $null = New-Item -ItemType Directory -Force -Path $toolDir

    $targets = @(
        @{
            Plink = "https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe"
            Pscp = "https://the.earth.li/~sgtatham/putty/latest/w64/pscp.exe"
        },
        @{
            Plink = "https://the.earth.li/~sgtatham/putty/latest/w32/plink.exe"
            Pscp = "https://the.earth.li/~sgtatham/putty/latest/w32/pscp.exe"
        }
    )

    foreach ($variant in $targets) {
        $plinkPath = Join-Path $toolDir "plink.exe"
        $pscpPath = Join-Path $toolDir "pscp.exe"

        $plinkOk = Invoke-WithRetry -Label "download plink.exe" -Attempts 6 -BaseDelaySeconds 5 -Action {
            Invoke-WebRequest -Uri $variant.Plink -OutFile $plinkPath -TimeoutSec 180
            if (-not (Test-Path $plinkPath)) {
                throw "plink download did not produce a file."
            }
        }
        if (-not $plinkOk) {
            continue
        }

        $pscpOk = Invoke-WithRetry -Label "download pscp.exe" -Attempts 6 -BaseDelaySeconds 5 -Action {
            Invoke-WebRequest -Uri $variant.Pscp -OutFile $pscpPath -TimeoutSec 180
            if (-not (Test-Path $pscpPath)) {
                throw "pscp download did not produce a file."
            }
        }
        if (-not $pscpOk) {
            continue
        }

        if ((Test-Path $plinkPath) -and (Test-Path $pscpPath)) {
            return $true
        }
    }

    return $false
}

function Ensure-PuttyTools {
    if (Resolve-PuttyToolsFromKnownLocations) {
        return $true
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "plink/pscp not found. attempting to install PuTTY with winget..."
        $wingetResult = Invoke-WingetInstallWithRetry -PackageId "PuTTY.PuTTY" -Attempts 6 -BaseDelaySeconds 8
        if (-not $wingetResult.Success) {
            Write-Host "winget install PuTTY.PuTTY failed after retries."
            Write-Host "diagnosis: $($wingetResult.Summary) (kind=$($wingetResult.Kind), exit=$($wingetResult.ExitCode))"
            if (-not [string]::IsNullOrWhiteSpace($wingetResult.Tail)) {
                Write-Host "winget output tail: $($wingetResult.Tail)"
            }
        }

        if (Resolve-PuttyToolsFromKnownLocations) {
            return $true
        }
    }

    Write-Host "winget install did not provide plink/pscp. attempting portable PuTTY download..."
    if ((Download-PuttyPortableTools) -and (Resolve-PuttyToolsFromKnownLocations)) {
        Write-Host "downloaded portable plink/pscp into %LOCALAPPDATA%\sticky-codex\tools."
        return $true
    }

    return $false
}

function Initialize-ProfileIfMissing {
    if (Test-Path $script:ProfileFile) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($script:HostName) -and -not [string]::IsNullOrWhiteSpace($script:UserName) -and -not [string]::IsNullOrWhiteSpace($script:RemoteProjectDir)) {
        return
    }

    if (-not [Environment]::UserInteractive) {
        Write-Host "connection profile was not found: $script:ProfileFile"
        Write-Host "run quick-install once to create it, or pass one-run overrides."
        exit 1
    }

    Write-Host "connection profile not found. creating one now..."
    Write-Host ""

    $defaultHostAlias = if ([string]::IsNullOrWhiteSpace($script:HostAlias)) { "myvps" } else { $script:HostAlias }
    $script:HostAlias = Prompt-WithDefault -Prompt "host alias" -Default $defaultHostAlias
    $script:HostName = Prompt-Required -Prompt "remote host (ip or domain)" -Default $script:HostName
    $defaultUserName = if ([string]::IsNullOrWhiteSpace($script:UserName)) { "root" } else { $script:UserName }
    $script:UserName = Prompt-Required -Prompt "remote user" -Default $defaultUserName
    $script:Port = [int](Prompt-WithDefault -Prompt "ssh port" -Default "$script:Port")
    $script:RemoteProjectDir = Prompt-Required -Prompt "remote project directory" -Default $script:RemoteProjectDir
    $script:SessionName = Prompt-WithDefault -Prompt "session name (blank for auto)" -Default $script:SessionName
    $script:IdleDays = [int](Prompt-WithDefault -Prompt "idle days before stale session cleanup" -Default "$script:IdleDays")
    $script:ReconnectDelaySeconds = [int](Prompt-WithDefault -Prompt "reconnect delay seconds" -Default "$script:ReconnectDelaySeconds")

    while ($true) {
        $mode = (Prompt-WithDefault -Prompt "ssh auth mode (auto/key/password)" -Default $script:AuthMode).ToLowerInvariant()
        if ($mode -in @("auto", "key", "password")) {
            $script:AuthMode = $mode
            break
        }
        Write-Host "please enter auto, key, or password."
    }

    if ($script:AuthMode -in @("auto", "key")) {
        $script:IdentityFile = Prompt-WithDefault -Prompt "ssh identity file path (optional)" -Default $script:IdentityFile
    }

    if ($script:AuthMode -eq "password" -and [string]::IsNullOrWhiteSpace($script:Password)) {
        $secure = Read-Host "ssh password (stored in profile)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $script:Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    $syncChoice = (Prompt-WithDefault -Prompt "sync local Codex auth.json before attach? (Y/n)" -Default "Y").ToLowerInvariant()
    $script:NoSyncAuth = ($syncChoice -in @("n", "no"))

    $upstreamDefault = "no"
    if ($script:ProxyType -in @("socks5", "http")) {
        $upstreamDefault = $script:ProxyType
    } elseif (($script:ProxyType -eq "quic" -or $script:ProxyType -eq "wss") -and $script:QuicUpstreamType -in @("no", "socks5", "http")) {
        $upstreamDefault = $script:QuicUpstreamType
    }

    $upstreamType = "no"
    while ($true) {
        $upstreamChoice = (Prompt-WithDefault -Prompt "Use upstream proxy? no/socks5/http" -Default $upstreamDefault).ToLowerInvariant()
        if ($upstreamChoice -in @("no", "socks5", "http")) {
            $upstreamType = $upstreamChoice
            break
        }
        Write-Host "please enter no, socks5, or http."
    }

    $upstreamSpec = ""
    if ($upstreamType -in @("socks5", "http")) {
        $upstreamSpecDefault = $script:ProxySpec
        if ($script:ProxyType -eq "quic" -or $script:ProxyType -eq "wss") {
            $upstreamSpecDefault = $script:QuicUpstreamSpec
        }
        $upstreamSpec = Prompt-Required -Prompt "upstream proxy address (host:port or host:port:username:password)" -Default $upstreamSpecDefault
    }

    $enableWss = $false
    while ($true) {
        $wssChoice = (Prompt-WithDefault -Prompt "Use wss stability layer? y/n" -Default "y").ToLowerInvariant()
        if ($wssChoice -in @("y", "yes")) {
            $enableWss = $true
            break
        }
        if ($wssChoice -in @("n", "no")) {
            $enableWss = $false
            break
        }
        Write-Host "please enter y or n."
    }

    if ($enableWss) {
        $script:ProxyType = "wss"
        $script:QuicServer = Prompt-WithDefault -Prompt "wss server host" -Default $(if ([string]::IsNullOrWhiteSpace($script:QuicServer)) { $script:HostName } else { $script:QuicServer })
        if ($script:QuicPort -eq 61313) {
            $script:QuicPort = 13131
        }
        $script:QuicPort = [int](Prompt-WithDefault -Prompt "wss server port" -Default "$script:QuicPort")
        $quicPrompt = "wss password (stored in profile)"
        if (-not [string]::IsNullOrWhiteSpace($script:QuicPassword)) {
            $quicPrompt = "wss password (stored in profile) [previous password]"
        }
        $secureQuic = Read-Host $quicPrompt -AsSecureString
        $qbstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureQuic)
        try {
            $qp = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($qbstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($qbstr)
        }
        if (-not [string]::IsNullOrWhiteSpace($qp)) {
            $script:QuicPassword = $qp
        }
        $script:QuicSni = Prompt-WithDefault -Prompt "wss tls sni (blank=server host)" -Default $(if ([string]::IsNullOrWhiteSpace($script:QuicSni)) { $script:QuicServer } else { $script:QuicSni })
        $wssLocalDefault = $script:QuicLocalSocksPort
        if ($wssLocalDefault -eq 10809) {
            $wssLocalDefault = 10819
        }
        $script:QuicLocalSocksPort = [int](Prompt-WithDefault -Prompt "local socks port for wss tunnel" -Default "$wssLocalDefault")
        $script:QuicUpstreamType = $upstreamType
        $script:QuicUpstreamSpec = $upstreamSpec
        $script:ProxySpec = ""
    } else {
        $script:ProxyType = $upstreamType
        $script:ProxySpec = $upstreamSpec
        $script:QuicServer = ""
        $script:QuicPassword = ""
        $script:QuicSni = ""
        $script:QuicUpstreamType = "no"
        $script:QuicUpstreamSpec = ""
    }

    Write-ProfileFile -Path $script:ProfileFile
    Write-Host "saved connection profile: $script:ProfileFile"
    Write-Host ""
}

function Resolve-ProfileFile {
    if ($script:CliBoundParams.ContainsKey("ProfileFile")) {
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

    if (-not $script:CliBoundParams.ContainsKey("Port")) {
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

    if (-not $script:CliBoundParams.ContainsKey("IdleDays")) {
        $profileIdle = Get-ProfileValue -Map $profileMap -Key "IDLE_DAYS"
        if (-not [string]::IsNullOrWhiteSpace($profileIdle)) {
            try {
                $script:IdleDays = [int]$profileIdle
            } catch {
            }
        }
    }

    if (-not $script:CliBoundParams.ContainsKey("ReconnectDelaySeconds")) {
        $profileDelay = Get-ProfileValue -Map $profileMap -Key "RECONNECT_DELAY_SECONDS"
        if (-not [string]::IsNullOrWhiteSpace($profileDelay)) {
            try {
                $script:ReconnectDelaySeconds = [int]$profileDelay
            } catch {
            }
        }
    }

    if (-not $script:CliBoundParams.ContainsKey("NoSyncAuth")) {
        $profileSync = Get-ProfileValue -Map $profileMap -Key "SYNC_AUTH"
        if ($profileSync -eq "0") {
            $script:NoSyncAuth = $true
        }
    }

    if (-not $script:CliBoundParams.ContainsKey("RemoteScript")) {
        $script:RemoteScript = Get-ProfileValue -Map $profileMap -Key "REMOTE_SCRIPT" -Fallback "/usr/local/bin/codex-vps"
    }

    if (-not $script:CliBoundParams.ContainsKey("AuthMode")) {
        $profileAuth = Get-ProfileValue -Map $profileMap -Key "AUTH_MODE" -Fallback "auto"
        if ($profileAuth -in @("auto", "key", "password")) {
            $script:AuthMode = $profileAuth
        }
    }

    if (-not $script:CliBoundParams.ContainsKey("Password")) {
        $script:Password = Decode-Base64 (Get-ProfileValue -Map $profileMap -Key "PASSWORD_B64")
        if ([string]::IsNullOrWhiteSpace($script:Password)) {
            $script:Password = Get-ProfileValue -Map $profileMap -Key "PASSWORD"
        }
    }

    if (-not $script:CliBoundParams.ContainsKey("ProxyType")) {
        $profileProxyType = (Get-ProfileValue -Map $profileMap -Key "PROXY_TYPE" -Fallback "no").ToLowerInvariant()
        if ($profileProxyType -in @("no", "socks5", "http", "quic", "wss")) {
            $script:ProxyType = $profileProxyType
        }
    }

    if (-not $script:CliBoundParams.ContainsKey("ProxySpec")) {
        $script:ProxySpec = Get-ProfileValue -Map $profileMap -Key "PROXY_SPEC"
    }

    if (-not $script:CliBoundParams.ContainsKey("QuicServer")) {
        $script:QuicServer = Get-ProfileValue -Map $profileMap -Key "QUIC_SERVER"
    }
    if (-not $script:CliBoundParams.ContainsKey("QuicPort")) {
        $qp = Get-ProfileValue -Map $profileMap -Key "QUIC_PORT"
        if (-not [string]::IsNullOrWhiteSpace($qp)) {
            try {
                $script:QuicPort = [int]$qp
            } catch {
            }
        }
    }
    if (-not $script:CliBoundParams.ContainsKey("QuicPassword")) {
        $script:QuicPassword = Decode-Base64 (Get-ProfileValue -Map $profileMap -Key "QUIC_PASSWORD_B64")
        if ([string]::IsNullOrWhiteSpace($script:QuicPassword)) {
            $script:QuicPassword = Get-ProfileValue -Map $profileMap -Key "QUIC_PASSWORD"
        }
    }
    if (-not $script:CliBoundParams.ContainsKey("QuicSni")) {
        $script:QuicSni = Get-ProfileValue -Map $profileMap -Key "QUIC_SNI"
    }
    if (-not $script:CliBoundParams.ContainsKey("QuicLocalSocksPort")) {
        $qlp = Get-ProfileValue -Map $profileMap -Key "QUIC_LOCAL_SOCKS_PORT"
        if (-not [string]::IsNullOrWhiteSpace($qlp)) {
            try {
                $script:QuicLocalSocksPort = [int]$qlp
            } catch {
            }
        }
    }
    if (-not $script:CliBoundParams.ContainsKey("QuicUpstreamType")) {
        $profileQuicUpstreamType = (Get-ProfileValue -Map $profileMap -Key "QUIC_UPSTREAM_TYPE" -Fallback "no").ToLowerInvariant()
        if ($profileQuicUpstreamType -in @("no", "socks5", "http")) {
            $script:QuicUpstreamType = $profileQuicUpstreamType
        }
    }
    if (-not $script:CliBoundParams.ContainsKey("QuicUpstreamSpec")) {
        $script:QuicUpstreamSpec = Get-ProfileValue -Map $profileMap -Key "QUIC_UPSTREAM_SPEC"
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
        if ($script:ReconnectDelaySeconds -lt 1) {
            $script:ReconnectDelaySeconds = 1
        }
        if ($script:AuthMode -eq "password" -and [string]::IsNullOrWhiteSpace($script:Password)) {
            throw "auth mode 'password' requires a saved password in the profile (PASSWORD_B64) or -Password."
        }
        if ([string]::IsNullOrWhiteSpace($script:ProxyType)) {
            $script:ProxyType = "no"
        }
        if ($script:ProxyType -notin @("no", "socks5", "http", "quic", "wss")) {
            throw "invalid proxy type: $script:ProxyType (expected no|socks5|http|quic|wss)"
        }
        if ($script:ProxyType -eq "quic") {
            Write-Host "proxy type 'quic' is deprecated; using 'wss' stability mode."
            $script:ProxyType = "wss"
        }
        if ($script:ProxyType -in @("socks5", "http") -and [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
            throw "proxy is enabled but proxy spec is empty."
        }
        if ($script:ProxyType -eq "quic" -or $script:ProxyType -eq "wss") {
            if ([string]::IsNullOrWhiteSpace($script:QuicServer)) {
                $script:QuicServer = $HostName
            }
            if ($script:ProxyType -eq "wss" -and $script:QuicPort -eq 61313) {
                $script:QuicPort = 13131
            }
            if ($script:ProxyType -eq "wss" -and $script:QuicLocalSocksPort -eq 10809) {
                $script:QuicLocalSocksPort = 10819
            }
            if ([string]::IsNullOrWhiteSpace($script:QuicPassword)) {
                throw "proxy type '$script:ProxyType' requires QUIC_PASSWORD_B64 (or -QuicPassword)."
            }
            if ($script:QuicPort -le 0 -or $script:QuicPort -gt 65535) {
                throw "proxy type '$script:ProxyType' requires a valid QUIC_PORT."
            }
            if ($script:QuicLocalSocksPort -le 0 -or $script:QuicLocalSocksPort -gt 65535) {
                throw "proxy type '$script:ProxyType' requires a valid QUIC_LOCAL_SOCKS_PORT."
            }
            if ($script:QuicUpstreamType -notin @("no", "socks5", "http")) {
                throw "proxy type '$script:ProxyType' has invalid QUIC_UPSTREAM_TYPE: $script:QuicUpstreamType (expected no|socks5|http)."
            }
            if ($script:QuicUpstreamType -in @("socks5", "http") -and [string]::IsNullOrWhiteSpace($script:QuicUpstreamSpec)) {
                throw "proxy type '$script:ProxyType' with upstream mode '$script:QuicUpstreamType' requires QUIC_UPSTREAM_SPEC."
            }
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

function Ensure-NpmForCodex {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) {
        return $true
    }

    Write-Host "npm is missing. attempting to install Node.js LTS..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        return $false
    }

    foreach ($pkgId in @("OpenJS.NodeJS.LTS", "OpenJS.NodeJS")) {
        $wingetResult = Invoke-WingetInstallWithRetry -PackageId $pkgId -Attempts 5 -BaseDelaySeconds 8
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            return $true
        }
        if ($wingetResult.Kind -eq "package-not-found") {
            continue
        }
    }

    return [bool](Get-Command npm -ErrorAction SilentlyContinue)
}

function Install-LocalCodexCli {
    if (-not (Ensure-NpmForCodex)) {
        return $false
    }

    $npmCmd = (Get-Command npm -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($npmCmd)) {
        return $false
    }

    $ok = Invoke-WithRetry -Label "install @openai/codex with npm" -Attempts 5 -BaseDelaySeconds 6 -Action {
        $output = (& $npmCmd "install" "-g" "@openai/codex" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "npm install exited with code $LASTEXITCODE. tail: $(Get-TextTail -Text $output -MaxLines 10)"
        }
    }
    if (-not $ok) {
        return $false
    }

    return [bool](Get-Command codex -ErrorAction SilentlyContinue)
}

function Ensure-Codex {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($codex) {
        return
    }

    if ([Environment]::UserInteractive) {
        $choice = (Prompt-WithDefault -Prompt "codex cli is missing on this Windows client. install now? (Y/n)" -Default "Y").ToLowerInvariant()
        if ($choice -notin @("n", "no")) {
            if (Install-LocalCodexCli) {
                return
            }
            Write-Host "automatic local codex install failed."
        }
    }

    throw "codex cli is not installed or not in PATH on this Windows machine."
}

function Select-SshBackend {
    if ($AuthMode -ne "password" -or [string]::IsNullOrWhiteSpace($Password)) {
        $script:SshBackend = "openssh"
        return
    }

    if (Ensure-PuttyTools) {
        $script:SshBackend = "putty"
        Write-Host "using plink/pscp backend for non-interactive password reconnects."
        return
    }

    throw "password auth requires plink/pscp for non-interactive reconnects on Windows. install PuTTY (or rerun quick-install) or switch to key/auto auth."
}

function Ensure-PuttyHostKeyCached {
    if ($script:SshBackend -ne "putty") {
        return
    }

    $targetHost = Get-SshTargetHost

    $baseArgs = @("-ssh", "-batch", "-P", "$Port", "-l", $UserName)
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $baseArgs += @("-i", $IdentityFile)
    }
    if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
        $baseArgs += @("-pw", $Password)
    }
    $baseArgs += Get-PuttyProxyArgs

    $pins = Resolve-PuttyHostKeyPins -TargetHost $targetHost
    if ($pins.Count -gt 0) {
        $script:PuttyHostKeyPins = $pins
        Write-Host ("PuTTY host key pinned for {0}: {1}" -f $targetHost, ($pins -join ", "))
    }

    $batchArgs = @($baseArgs + (Get-PuttyHostKeyArgs) + @($targetHost, "true"))
    $batchResult = Invoke-NativeCapture -FilePath $script:PlinkExe -Arguments $batchArgs
    if ([int]$batchResult.ExitCode -eq 0) {
        return
    }

    $discovered = Get-Sha256PinsFromText -Text ([string]$batchResult.Output)
    if ($discovered.Count -eq 0) {
        $probeArgs = @($baseArgs + @("-v", $targetHost, "true"))
        $probe = Invoke-NativeCapture -FilePath $script:PlinkExe -Arguments $probeArgs
        $discovered = Get-Sha256PinsFromText -Text ([string]$probe.Output)
    }
    if ($discovered.Count -eq 0) {
        $probeText = ""
        $oldNativePreference = $null
        $hasNativePreference = $false
        try {
            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
                $hasNativePreference = $true
                $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
                $global:PSNativeCommandUseErrorActionPreference = $false
            }
            $probeText = (& $script:PlinkExe @($baseArgs + @("-v", $targetHost, "true")) 2>&1 | Out-String)
        } catch {
            $msg = ""
            if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                $msg = $_.Exception.Message
            } else {
                $msg = ($_ | Out-String).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($probeText)) {
                $probeText = $msg
            } else {
                $probeText = ($probeText + [Environment]::NewLine + $msg).Trim()
            }
        } finally {
            if ($hasNativePreference) {
                $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
            }
        }
        $discovered = Get-Sha256PinsFromText -Text $probeText
    }
    if ($discovered.Count -gt 0) {
        $script:PuttyHostKeyPins = $discovered
        Write-Host ("PuTTY host key pinned for {0}: {1}" -f $targetHost, ($discovered -join ", "))
        $verifyArgs = @($baseArgs + (Get-PuttyHostKeyArgs) + @($targetHost, "true"))
        $verify = Invoke-NativeCapture -FilePath $script:PlinkExe -Arguments $verifyArgs
        if ([int]$verify.ExitCode -eq 0) {
            return
        }
    }

    $lower = ([string]$batchResult.Output).ToLowerInvariant()
    if ($lower -match "host key is not cached|cannot confirm a host key in batch mode|potential security breach|host identification has changed|host key does not match|store key in cache") {
        Write-Host "warning: could not auto-pin the PuTTY host key fingerprint from probe output. falling back to cached host key behavior."
    }
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

    $script:LastRemoteSshExitCode = 1

    if ($script:SshBackend -eq "putty") {
        $targetHost = Get-SshTargetHost
        $args = @("-ssh", "-P", "$Port", "-l", $UserName)

        if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
            $args += @("-i", $IdentityFile)
        }

        if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
            $args += @("-pw", $Password)
        }

        $args += Get-PuttyProxyArgs
        $args += Get-PuttyHostKeyArgs

        $oldNativePreference = $null
        $hasNativePreference = $false
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
            $hasNativePreference = $true
            $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
            $global:PSNativeCommandUseErrorActionPreference = $false
        }
        try {
            if ($Interactive) {
                $args += @("-no-antispoof", "-t", $targetHost, $RemoteCommand)
                & $script:PlinkExe @args
            } else {
                $args += @("-batch", $targetHost, $RemoteCommand)
                & $script:PlinkExe @args
            }
            $script:LastRemoteSshExitCode = [int]$LASTEXITCODE
            if (-not $Interactive) {
                return $script:LastRemoteSshExitCode
            }
            return
        } catch {
            $nativeExit = 0
            try {
                $nativeExit = [int]$LASTEXITCODE
            } catch {
                $nativeExit = 0
            }
            if ($nativeExit -gt 0) {
                $script:LastRemoteSshExitCode = $nativeExit
            } else {
                $script:LastRemoteSshExitCode = 1
            }
            if (-not $Interactive) {
                return $script:LastRemoteSshExitCode
            }
            return
        } finally {
            if ($hasNativePreference) {
                $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
            }
        }
    }

    $args = @("-F", $script:SshConfigPath)
    if ($Interactive) {
        $args += "-tt"
    }
    $args += @($HostAlias, $RemoteCommand)
    & ssh @args
    $script:LastRemoteSshExitCode = [int]$LASTEXITCODE
    if (-not $Interactive) {
        return $script:LastRemoteSshExitCode
    }
    return
}

function Invoke-RemoteSshCapture {
    param(
        [string]$RemoteCommand,
        [switch]$Interactive
    )

    $output = ""
    $exitCode = 1
    $oldNativePreference = $null
    $hasNativePreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        $hasNativePreference = $true
        $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
        $global:PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        if ($script:SshBackend -eq "putty") {
            $targetHost = Get-SshTargetHost
            $args = @("-ssh", "-P", "$Port", "-l", $UserName)

            if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
                $args += @("-i", $IdentityFile)
            }

            if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
                $args += @("-pw", $Password)
            }

            $args += Get-PuttyProxyArgs
            $args += Get-PuttyHostKeyArgs

            if ($Interactive) {
                $args += @("-t", $targetHost, $RemoteCommand)
            } else {
                $args += @("-batch", $targetHost, $RemoteCommand)
            }

            $native = Invoke-NativeCapture -FilePath $script:PlinkExe -Arguments $args
            $output = [string]$native.Output
            $exitCode = [int]$native.ExitCode
        } else {
            $args = @("-F", $script:SshConfigPath)
            if ($Interactive) {
                $args += "-tt"
            }
            $args += @($HostAlias, $RemoteCommand)

            $output = (& ssh @args 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        }
    } catch {
        $caughtText = ""
        if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
            $caughtText = $_.Exception.Message
        } else {
            $caughtText = ($_ | Out-String).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = $caughtText
        } else {
            $output = ($output + [Environment]::NewLine + $caughtText).Trim()
        }
        $nativeExit = 0
        try {
            $nativeExit = [int]$LASTEXITCODE
        } catch {
            $nativeExit = 0
        }
        if ($nativeExit -gt 0) {
            $exitCode = $nativeExit
        } else {
            $exitCode = 1
        }
    } finally {
        if ($hasNativePreference) {
            $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    return @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Invoke-RemoteScp {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    if ($script:SshBackend -eq "putty") {
        $targetHost = Get-SshTargetHost
        $args = @("-P", "$Port", "-l", $UserName)

        if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
            $args += @("-i", $IdentityFile)
        }

        if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
            $args += @("-pw", $Password)
        }

        $args += Get-PuttyProxyArgs
        $args += Get-PuttyHostKeyArgs

        $args += @($LocalPath, "$targetHost`:$RemotePath")
        $native = Invoke-NativeCapture -FilePath $script:PscpExe -Arguments $args
        return @{
            ExitCode = [int]$native.ExitCode
            Output = [string]$native.Output
        }
    }

    $output = (& scp -F $script:SshConfigPath $LocalPath "$HostAlias`:$RemotePath" 2>&1 | Out-String)
    return @{
        ExitCode = [int]$LASTEXITCODE
        Output = [string]$output
    }
}

function Install-RemoteCodexCli {
    $installScript = @'
set -e
has_command() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if has_command sudo; then
    SUDO="sudo"
  fi
fi

run_priv() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

add_npm_path() {
  local prefix nbin
  if has_command npm; then
    prefix="$(npm config get prefix 2>/dev/null || true)"
    if [ -n "$prefix" ] && [ -d "$prefix/bin" ]; then
      PATH="$prefix/bin:$PATH"
    fi
    nbin="$(npm bin -g 2>/dev/null || true)"
    if [ -n "$nbin" ] && [ -d "$nbin" ]; then
      PATH="$nbin:$PATH"
    fi
  fi
  PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
}

find_codex_bin() {
  local p nbin
  add_npm_path
  if has_command codex; then
    command -v codex
    return 0
  fi
  for p in "$HOME/.npm-global/bin/codex" "$HOME/.local/bin/codex" "/usr/local/bin/codex"; do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  if has_command npm; then
    nbin="$(npm bin -g 2>/dev/null || true)"
    if [ -n "$nbin" ] && [ -x "$nbin/codex" ]; then
      printf '%s\n' "$nbin/codex"
      return 0
    fi
  fi
  return 1
}

ensure_npm() {
  if has_command npm; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    echo "npm is missing and sudo is not available; cannot install Node.js automatically." >&2
    return 1
  fi

  if has_command apt-get; then
    run_priv apt-get update || true
    run_priv apt-get install -y nodejs npm || true
  elif has_command dnf; then
    run_priv dnf install -y nodejs npm || true
  elif has_command yum; then
    run_priv yum install -y nodejs npm || true
  elif has_command pacman; then
    run_priv pacman -Sy --noconfirm nodejs npm || true
  elif has_command zypper; then
    run_priv zypper --non-interactive install nodejs npm || true
  elif has_command apk; then
    run_priv apk add nodejs npm || true
  fi

  has_command npm
}

install_codex_package() {
  npm install -g @openai/codex && return 0
  npm install --location=global @openai/codex && return 0
  return 1
}

link_codex_if_needed() {
  local codex_path="$1"
  add_npm_path
  if has_command codex; then
    return 0
  fi
  if [ -w /usr/local/bin ]; then
    ln -sf "$codex_path" /usr/local/bin/codex || true
  elif [ -n "$SUDO" ]; then
    run_priv ln -sf "$codex_path" /usr/local/bin/codex || true
  fi
  add_npm_path
  has_command codex
}

if ! ensure_npm; then
  echo "remote install could not find npm even after package install attempts." >&2
  exit 1
fi

attempt=1
while [ "$attempt" -le 5 ]; do
  if find_codex_bin >/dev/null 2>&1; then
    break
  fi
  if install_codex_package; then
    :
  fi
  if find_codex_bin >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -lt 5 ]; then
    delay=$(( attempt * 5 ))
    if [ "$delay" -gt 30 ]; then
      delay=30
    fi
    echo "remote npm install @openai/codex failed (attempt $attempt/5). retrying in $delay seconds..." >&2
    sleep "$delay"
  fi
  attempt=$((attempt + 1))
done

codex_path="$(find_codex_bin || true)"
if [ -z "$codex_path" ]; then
  echo "remote codex install completed but codex binary was not found." >&2
  exit 1
fi

if ! link_codex_if_needed "$codex_path"; then
  echo "codex was found at $codex_path but is not in PATH for non-interactive shells." >&2
  exit 1
fi

if ! codex --version >/dev/null 2>&1; then
  echo "codex command exists but failed to run 'codex --version'." >&2
  exit 1
fi
'@

    $cmd = "bash -lc " + (Quote-ForBashSingle $installScript)
    Invoke-RemoteSsh -Interactive -RemoteCommand $cmd
    $exitCode = [int]$script:LastRemoteSshExitCode
    return ($exitCode -eq 0)
}

function Resolve-RemoteHomePath {
    $cmd = "bash -lc " + (Quote-ForBashSingle 'printf %s "$HOME"')
    $result = Invoke-RemoteSshCapture -RemoteCommand $cmd
    if ($result.ExitCode -eq 0) {
        $text = [string]$result.Output
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            foreach ($line in ($text -split "(`r`n|`n|`r)")) {
                $trimmed = $line.Trim()
                if ($trimmed.StartsWith("/")) {
                    return $trimmed
                }
            }
        }
    }

    if ($UserName -eq "root") {
        return "/root"
    }
    if (-not [string]::IsNullOrWhiteSpace($UserName)) {
        return "/home/$UserName"
    }
    return "/root"
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

    Write-Host "syncing local Codex auth to VPS over active SSH transport..."
    $remoteHome = Resolve-RemoteHomePath
    $remoteCodexDir = ($remoteHome.TrimEnd("/") + "/.codex")
    $remoteAuthPath = ($remoteCodexDir + "/auth.json")
    $remoteCodexDirArg = Quote-ForBashSingle $remoteCodexDir
    $remoteAuthArg = Quote-ForBashSingle $remoteAuthPath

    $prepareCmd = "bash -lc " + (Quote-ForBashSingle "mkdir -p $remoteCodexDirArg && chmod 700 $remoteCodexDirArg")
    $verifyCmd = "bash -lc " + (Quote-ForBashSingle "if [ -s $remoteAuthArg ]; then chmod 600 $remoteAuthArg || true; exit 0; fi; exit 32")

    $maxAttempts = 8
    $lastDetail = ""
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $prepareResult = Invoke-RemoteSshCapture -RemoteCommand $prepareCmd
        if ($prepareResult.ExitCode -ne 0) {
            $lastDetail = Get-TextTail -Text ([string]$prepareResult.Output) -MaxLines 10
            if ($attempt -lt $maxAttempts) {
                $delay = [Math]::Min(15, [Math]::Max(1, $attempt * 2))
                Write-Host "auth sync prepare failed (attempt $attempt/$maxAttempts). retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }

        $copyResult = Invoke-RemoteScp -LocalPath $localAuth -RemotePath $remoteAuthPath
        if ($copyResult.ExitCode -ne 0) {
            $lastDetail = Get-TextTail -Text ([string]$copyResult.Output) -MaxLines 10
            if ($attempt -lt $maxAttempts) {
                $delay = [Math]::Min(15, [Math]::Max(1, $attempt * 2))
                Write-Host "auth sync copy failed (attempt $attempt/$maxAttempts). retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }

        $verifyResult = Invoke-RemoteSshCapture -RemoteCommand $verifyCmd
        if ($verifyResult.ExitCode -eq 0) {
            return
        }
        $lastDetail = Get-TextTail -Text ([string]$verifyResult.Output) -MaxLines 10
        if ($attempt -lt $maxAttempts) {
            $delay = [Math]::Min(15, [Math]::Max(1, $attempt * 2))
            Write-Host "auth sync verify failed (attempt $attempt/$maxAttempts). retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
            continue
        }
    }

    if ([string]::IsNullOrWhiteSpace($lastDetail)) {
        throw "failed to copy auth.json to the remote host."
    }
    throw "failed to copy auth.json to the remote host. details: $lastDetail"
}

function Quote-ForBashSingle {
    param([string]$Text)
    return "'" + ($Text -replace "'", "'""'""'") + "'"
}

function Write-TempSshConfig {
    $targetHost = Get-SshTargetHost
    $lines = @()
    $lines += "Host $HostAlias"
    $lines += "    HostName $targetHost"
    $lines += "    User $UserName"
    $lines += "    Port $Port"
    $lines += "    ServerAliveInterval 15"
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

    if ($script:SshBackend -eq "openssh" -and $script:ProxyType -ne "no" -and -not [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
        $lines += "    ProxyCommand $(Build-NcatProxyCommand -TargetHostToken '%h' -TargetPortToken '%p')"
    }

    Set-Content -Path $script:SshConfigPath -Value ($lines -join "`r`n")
}

function Test-RemotePrereqs {
    $remoteScriptArg = Quote-ForBashSingle $RemoteScript
    $projectArg = Quote-ForBashSingle $RemoteProjectDir
    $check = @"
if [ ! -x $remoteScriptArg ]; then
  echo "remote script not found or not executable: $RemoteScript" >&2
  exit 20
fi
if [ ! -d $projectArg ]; then
  echo "remote project directory not found - creating: $RemoteProjectDir" >&2
  if ! mkdir -p $projectArg; then
    echo "failed to create remote project directory: $RemoteProjectDir" >&2
    exit 21
  fi
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "codex is not installed or not in PATH on the remote host." >&2
  exit 22
fi
"@
    $cmd = "bash -lc " + (Quote-ForBashSingle $check)
    $result = Invoke-RemoteSshCapture -RemoteCommand $cmd
    $exitCode = $result.ExitCode
    if ($exitCode -eq 0) {
        $okOutput = ""
        if ($null -ne $result.Output) {
            $okOutput = [string]$result.Output
        }
        if (-not [string]::IsNullOrWhiteSpace($okOutput)) {
            $tail = Get-TextTail -Text $okOutput -MaxLines 6
            if (-not [string]::IsNullOrWhiteSpace($tail)) {
                Write-Host "remote preflight: $tail"
            }
        }
        return $true
    }

    $output = ""
    if ($null -ne $result.Output) {
        $output = [string]$result.Output
    }
    $outputLower = $output.ToLowerInvariant()
    $missingCodexDetected = ($exitCode -eq 22 -or ($outputLower -match "codex is not installed or not in path on the remote host"))

    if ($missingCodexDetected -and [Environment]::UserInteractive) {
        $choice = (Prompt-WithDefault -Prompt "remote codex is missing on $HostAlias. install now? (Y/n)" -Default "Y").ToLowerInvariant()
        if ($choice -notin @("n", "no")) {
            Write-Host "installing codex on remote host..."
            if (Install-RemoteCodexCli) {
                $verifyExit = Invoke-RemoteSsh -RemoteCommand "bash -lc 'command -v codex >/dev/null 2>&1'"
                if ($verifyExit -eq 0) {
                    Write-Host "remote codex install succeeded."
                    return $true
                }
            }
            Write-Host "automatic remote codex install failed."
        }
    }

    if ($exitCode -eq 255 -or $outputLower -match "connection refused|network error|timed out|timeout|name or service not known|could not resolve|no route to host|connection reset|connection closed|unexpectedly closed network connection|remote side unexpectedly closed") {
        $tail = Get-TextTail -Text $output -MaxLines 10
        if ($script:ProxyType -eq "wss") {
            Write-Host "wss hint: on the server, run 'sudo systemctl restart sticky-codex-wss.service' and inspect 'journalctl -u sticky-codex-wss.service --no-pager -n 80'."
        }
        if ([string]::IsNullOrWhiteSpace($tail)) {
            Write-Host "remote preflight failed due to SSH transport/connectivity issue (exit $exitCode)."
            return $false
        }
        Write-Host "remote preflight failed due to SSH transport/connectivity issue (exit $exitCode). details: $tail"
        return $false
    }

    if ($exitCode -ge 20 -and $exitCode -le 29) {
        throw "remote preflight failed with exit code $exitCode."
    }

    $tail = Get-TextTail -Text $output -MaxLines 10
    if ([string]::IsNullOrWhiteSpace($tail)) {
        Write-Host "remote preflight could not complete (exit $exitCode)."
        return $false
    }
    Write-Host "remote preflight could not complete (exit $exitCode). details: $tail"
    return $false
}

function Start-ReconnectLoop {
    $projectArg = Quote-ForBashSingle $RemoteProjectDir
    $sessionArg = Quote-ForBashSingle $SessionName
    $launchCmd = "$RemoteScript --project-dir $projectArg --session-name $sessionArg --idle-days $IdleDays"
    $remoteCmd = "bash -lc " + (Quote-ForBashSingle $launchCmd)

    while ($true) {
        Write-Host ""
        Write-Host "connecting to $HostAlias | session=$SessionName | project=$RemoteProjectDir"
        Invoke-RemoteSsh -Interactive -RemoteCommand $remoteCmd
        $exitCode = [int]$script:LastRemoteSshExitCode
        $delay = 1

        if ($exitCode -ne 0) {
            Write-Host "remote launcher exited with code $exitCode."
        }
        if ($exitCode -eq 255) {
            Write-Host "ssh transport failed (exit 255). check sshd/firewall/fail2ban/network reachability."
        }

        Write-Host ""
        Write-Host "disconnected. reconnecting in $delay seconds..."
        Start-Sleep -Seconds $delay
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

Resolve-ProfileFile
Initialize-ProfileIfMissing
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

Configure-ConsoleUtf8
Show-Banner
Ensure-WindowsOpenSsh
Ensure-Codex
Select-SshBackend
Ensure-WssLocalProxy
Ensure-QuicLocalProxy
Ensure-NcatForProxy
Ensure-PuttyHostKeyCached
Write-TempSshConfig
$preflightReady = Test-RemotePrereqs

if (-not $NoSyncAuth -and $preflightReady) {
    Sync-LocalCodexAuthToRemote
} elseif (-not $NoSyncAuth) {
    Write-Host "skipping local auth sync until remote connectivity stabilizes."
}

Start-ReconnectLoop

