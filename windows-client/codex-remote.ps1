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
    [ValidateSet("no", "socks5", "http", "quic")]
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
  -ReconnectDelaySeconds 3
  -AuthMode auto|key|password
  -Password yourpassword
  -ProxyType no|socks5|http|quic
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
    $ncatCmd = $script:NcatExe
    if ($ncatCmd -match "\s") {
        $ncatCmd = '"' + ($ncatCmd -replace '"', '\"') + '"'
    }

    $cmd = "$ncatCmd --proxy $($proxy.Host):$($proxy.Port) --proxy-type $type"
    if (-not [string]::IsNullOrWhiteSpace($proxy.Username)) {
        $cmd += " --proxy-auth $($proxy.Username):$($proxy.Password)"
    }
    $cmd += " $TargetHostToken $TargetPortToken"

    return $cmd
}

function Resolve-NcatExe {
    $ncat = Get-Command ncat -ErrorAction SilentlyContinue
    if ($ncat) {
        $script:NcatExe = $ncat.Source
        return $true
    }

    foreach ($candidate in @("$env:ProgramFiles\Nmap\ncat.exe", "${env:ProgramFiles(x86)}\Nmap\ncat.exe")) {
        if (Test-Path $candidate) {
            $script:NcatExe = $candidate
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
                    return $true
                }
            }
        }
    }

    return $false
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
        $choice = (Prompt-WithDefault -Prompt "quic core (sing-box) is missing on this client. install now? (Y/n)" -Default "Y").ToLowerInvariant()
        if ($choice -in @("n", "no")) {
            throw "quic mode requires sing-box on this client. install was skipped by user."
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

    throw "quic mode requires sing-box, but it could not be installed automatically."
}

function Test-TcpPort {
    param(
        [string]$Host,
        [int]$Port,
        [int]$TimeoutMs = 1200
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Host, $Port, $null, $null)
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

    if (Test-TcpPort -Host "127.0.0.1" -Port $script:QuicLocalSocksPort -TimeoutMs 900) {
        $script:ProxyType = "socks5"
        $script:ProxySpec = "127.0.0.1:$script:QuicLocalSocksPort"
        return
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
        if (Test-TcpPort -Host "127.0.0.1" -Port $script:QuicLocalSocksPort -TimeoutMs 600) {
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

function Get-PuttyProxyArgs {
    if ($script:ProxyType -eq "no" -or [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
        return @()
    }

    return @("-proxycmd", (Build-NcatProxyCommand -TargetHostToken "%host" -TargetPortToken "%port"))
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

    while ($true) {
        $proxyChoice = (Prompt-WithDefault -Prompt "Run through proxy? [no]  no/socks5/http/quic" -Default "no").ToLowerInvariant()
        if ($proxyChoice -in @("no", "socks5", "http", "quic")) {
            $script:ProxyType = $proxyChoice
            break
        }
        Write-Host "please enter no, socks5, http, or quic."
    }

    if ($script:ProxyType -in @("socks5", "http")) {
        $script:ProxySpec = Prompt-Required -Prompt "proxy address (host:port or host:port:username:password)" -Default $script:ProxySpec
        $script:QuicUpstreamType = "no"
        $script:QuicUpstreamSpec = ""
    } elseif ($script:ProxyType -eq "quic") {
        $script:QuicServer = Prompt-WithDefault -Prompt "quic server host" -Default $(if ([string]::IsNullOrWhiteSpace($script:QuicServer)) { $script:HostName } else { $script:QuicServer })
        $script:QuicPort = [int](Prompt-WithDefault -Prompt "quic server port" -Default "$script:QuicPort")
        $quicPrompt = "quic password (stored in profile)"
        if (-not [string]::IsNullOrWhiteSpace($script:QuicPassword)) {
            $quicPrompt = "quic password (stored in profile) [previous password]"
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
        $script:QuicSni = Prompt-WithDefault -Prompt "quic tls sni (blank=server host)" -Default $(if ([string]::IsNullOrWhiteSpace($script:QuicSni)) { $script:QuicServer } else { $script:QuicSni })
        $script:QuicLocalSocksPort = [int](Prompt-WithDefault -Prompt "local socks port for quic tunnel" -Default "$script:QuicLocalSocksPort")
        while ($true) {
            $upstreamChoice = (Prompt-WithDefault -Prompt "quic upstream proxy mode [no]  no/socks5/http" -Default $script:QuicUpstreamType).ToLowerInvariant()
            if ($upstreamChoice -in @("no", "socks5", "http")) {
                $script:QuicUpstreamType = $upstreamChoice
                break
            }
            Write-Host "please enter no, socks5, or http."
        }
        if ($script:QuicUpstreamType -in @("socks5", "http")) {
            $script:QuicUpstreamSpec = Prompt-Required -Prompt "quic upstream proxy address (host:port or host:port:username:password)" -Default $script:QuicUpstreamSpec
        } else {
            $script:QuicUpstreamSpec = ""
        }
        $script:ProxySpec = ""
    } else {
        $script:ProxySpec = ""
        $script:QuicUpstreamType = "no"
        $script:QuicUpstreamSpec = ""
    }

    Write-ProfileFile -Path $script:ProfileFile
    Write-Host "saved connection profile: $script:ProfileFile"
    Write-Host ""
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

    if (-not $PSBoundParameters.ContainsKey("ProxyType")) {
        $profileProxyType = (Get-ProfileValue -Map $profileMap -Key "PROXY_TYPE" -Fallback "no").ToLowerInvariant()
        if ($profileProxyType -in @("no", "socks5", "http", "quic")) {
            $script:ProxyType = $profileProxyType
        }
    }

    if (-not $PSBoundParameters.ContainsKey("ProxySpec")) {
        $script:ProxySpec = Get-ProfileValue -Map $profileMap -Key "PROXY_SPEC"
    }

    if (-not $PSBoundParameters.ContainsKey("QuicServer")) {
        $script:QuicServer = Get-ProfileValue -Map $profileMap -Key "QUIC_SERVER"
    }
    if (-not $PSBoundParameters.ContainsKey("QuicPort")) {
        $qp = Get-ProfileValue -Map $profileMap -Key "QUIC_PORT"
        if (-not [string]::IsNullOrWhiteSpace($qp)) {
            try {
                $script:QuicPort = [int]$qp
            } catch {
            }
        }
    }
    if (-not $PSBoundParameters.ContainsKey("QuicPassword")) {
        $script:QuicPassword = Decode-Base64 (Get-ProfileValue -Map $profileMap -Key "QUIC_PASSWORD_B64")
        if ([string]::IsNullOrWhiteSpace($script:QuicPassword)) {
            $script:QuicPassword = Get-ProfileValue -Map $profileMap -Key "QUIC_PASSWORD"
        }
    }
    if (-not $PSBoundParameters.ContainsKey("QuicSni")) {
        $script:QuicSni = Get-ProfileValue -Map $profileMap -Key "QUIC_SNI"
    }
    if (-not $PSBoundParameters.ContainsKey("QuicLocalSocksPort")) {
        $qlp = Get-ProfileValue -Map $profileMap -Key "QUIC_LOCAL_SOCKS_PORT"
        if (-not [string]::IsNullOrWhiteSpace($qlp)) {
            try {
                $script:QuicLocalSocksPort = [int]$qlp
            } catch {
            }
        }
    }
    if (-not $PSBoundParameters.ContainsKey("QuicUpstreamType")) {
        $profileQuicUpstreamType = (Get-ProfileValue -Map $profileMap -Key "QUIC_UPSTREAM_TYPE" -Fallback "no").ToLowerInvariant()
        if ($profileQuicUpstreamType -in @("no", "socks5", "http")) {
            $script:QuicUpstreamType = $profileQuicUpstreamType
        }
    }
    if (-not $PSBoundParameters.ContainsKey("QuicUpstreamSpec")) {
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
        if ($script:AuthMode -eq "password" -and [string]::IsNullOrWhiteSpace($script:Password)) {
            throw "auth mode 'password' requires a saved password in the profile (PASSWORD_B64) or -Password."
        }
        if ([string]::IsNullOrWhiteSpace($script:ProxyType)) {
            $script:ProxyType = "no"
        }
        if ($script:ProxyType -notin @("no", "socks5", "http", "quic")) {
            throw "invalid proxy type: $script:ProxyType (expected no|socks5|http|quic)"
        }
        if ($script:ProxyType -in @("socks5", "http") -and [string]::IsNullOrWhiteSpace($script:ProxySpec)) {
            throw "proxy is enabled but proxy spec is empty."
        }
        if ($script:ProxyType -eq "quic") {
            if ([string]::IsNullOrWhiteSpace($script:QuicServer)) {
                $script:QuicServer = $HostName
            }
            if ([string]::IsNullOrWhiteSpace($script:QuicPassword)) {
                throw "proxy type 'quic' requires QUIC_PASSWORD_B64 (or -QuicPassword)."
            }
            if ($script:QuicPort -le 0 -or $script:QuicPort -gt 65535) {
                throw "proxy type 'quic' requires a valid QUIC_PORT."
            }
            if ($script:QuicLocalSocksPort -le 0 -or $script:QuicLocalSocksPort -gt 65535) {
                throw "proxy type 'quic' requires a valid QUIC_LOCAL_SOCKS_PORT."
            }
            if ($script:QuicUpstreamType -notin @("no", "socks5", "http")) {
                throw "proxy type 'quic' has invalid QUIC_UPSTREAM_TYPE: $script:QuicUpstreamType (expected no|socks5|http)."
            }
            if ($script:QuicUpstreamType -in @("socks5", "http") -and [string]::IsNullOrWhiteSpace($script:QuicUpstreamSpec)) {
                throw "proxy type 'quic' with upstream mode '$script:QuicUpstreamType' requires QUIC_UPSTREAM_SPEC."
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

    $batchArgs = @("-ssh", "-batch", "-P", "$Port", "-l", $UserName)
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $batchArgs += @("-i", $IdentityFile)
    }
    if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
        $batchArgs += @("-pw", $Password)
    }
    $batchArgs += Get-PuttyProxyArgs
    $batchArgs += @($HostName, "true")

    $batchOutput = ""
    $batchExit = 1
    $oldNativePreference = $null
    $hasNativePreference = $false
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        $hasNativePreference = $true
        $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
        $global:PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        try {
            $batchOutput = (& $script:PlinkExe @batchArgs 2>&1 | Out-String)
            $batchExit = $LASTEXITCODE
        } catch {
            $batchOutput = ($_ | Out-String)
            if ($LASTEXITCODE -ne 0) {
                $batchExit = $LASTEXITCODE
            }
        }
    } finally {
        if ($hasNativePreference) {
            $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
    if ($batchExit -eq 0) {
        return
    }

    if ($batchOutput -notmatch "host key is not cached|cannot confirm a host key in batch mode") {
        return
    }

    if (-not [Environment]::UserInteractive) {
        throw "PuTTY host key for $HostName is not cached. run one interactive plink connection first to trust this host key."
    }

    Write-Host "PuTTY host key for $HostName is not cached. confirming once interactively..."
    $interactiveArgs = @("-ssh", "-P", "$Port", "-l", $UserName)
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $interactiveArgs += @("-i", $IdentityFile)
    }
    if ($AuthMode -eq "password" -and -not [string]::IsNullOrWhiteSpace($Password)) {
        $interactiveArgs += @("-pw", $Password)
    }
    $interactiveArgs += Get-PuttyProxyArgs
    $interactiveArgs += @($HostName, "exit")
    & $script:PlinkExe @interactiveArgs
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

        $args += Get-PuttyProxyArgs

        if ($Interactive) {
            $args += @("-t", $HostName, $RemoteCommand)
            & $script:PlinkExe @args
        } else {
            $args += @("-batch", $HostName, $RemoteCommand)
            & $script:PlinkExe @args
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

        $args += Get-PuttyProxyArgs

        $args += @($LocalPath, "$HostName`:$RemotePath")
        & $script:PscpExe @args
        return $LASTEXITCODE
    }

    & scp -F $script:SshConfigPath $LocalPath "$HostAlias`:$RemotePath"
    return $LASTEXITCODE
}

function Install-RemoteCodexCli {
    $installScript = @'
set -e
has_command() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if has_command sudo; then
    SUDO="sudo"
  else
    echo "remote install requires root privileges or sudo." >&2
    exit 1
  fi
fi

if ! has_command npm; then
  if has_command apt-get; then
    $SUDO apt-get update || true
    $SUDO apt-get install -y nodejs npm || true
  elif has_command dnf; then
    $SUDO dnf install -y nodejs npm || true
  elif has_command yum; then
    $SUDO yum install -y nodejs npm || true
  elif has_command pacman; then
    $SUDO pacman -Sy --noconfirm nodejs npm || true
  elif has_command zypper; then
    $SUDO zypper --non-interactive install nodejs npm || true
  elif has_command apk; then
    $SUDO apk add nodejs npm || true
  fi
fi

if ! has_command npm; then
  echo "remote install could not find npm even after package install attempts." >&2
  exit 1
fi

attempt=1
while [ "$attempt" -le 5 ]; do
  if npm install -g @openai/codex; then
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

if ! has_command codex; then
  echo "remote codex install completed but codex is still missing from PATH." >&2
  exit 1
fi
'@

    $cmd = "bash -lc " + (Quote-ForBashSingle $installScript)
    $exitCode = Invoke-RemoteSsh -Interactive -RemoteCommand $cmd
    return ($exitCode -eq 0)
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
  echo "remote project directory not found: $RemoteProjectDir" >&2
  exit 21
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "codex is not installed or not in PATH on the remote host." >&2
  exit 22
fi
"@
    $cmd = "bash -lc " + (Quote-ForBashSingle $check)
    $exitCode = Invoke-RemoteSsh -RemoteCommand $cmd
    if ($exitCode -eq 0) {
        return
    }

    if ($exitCode -eq 22 -and [Environment]::UserInteractive) {
        $choice = (Prompt-WithDefault -Prompt "remote codex is missing on $HostAlias. install now? (Y/n)" -Default "Y").ToLowerInvariant()
        if ($choice -notin @("n", "no")) {
            Write-Host "installing codex on remote host..."
            if (Install-RemoteCodexCli) {
                $verifyExit = Invoke-RemoteSsh -RemoteCommand "bash -lc 'command -v codex >/dev/null 2>&1'"
                if ($verifyExit -eq 0) {
                    Write-Host "remote codex install succeeded."
                    return
                }
            }
            Write-Host "automatic remote codex install failed."
        }
    }

    if ($exitCode -ge 20 -and $exitCode -le 29) {
        throw "remote preflight failed with exit code $exitCode."
    }

    Write-Host "remote preflight could not complete (exit $exitCode). continuing into reconnect loop."
}

function Start-ReconnectLoop {
    $rapidFailures = 0

    $projectArg = Quote-ForBashSingle $RemoteProjectDir
    $sessionArg = Quote-ForBashSingle $SessionName
    $launchCmd = "$RemoteScript --project-dir $projectArg --session-name $sessionArg --idle-days $IdleDays"
    $remoteCmd = "bash -lc " + (Quote-ForBashSingle $launchCmd)

    while ($true) {
        $startedAt = Get-Date
        Write-Host ""
        Write-Host "connecting to $HostAlias | session=$SessionName | project=$RemoteProjectDir"
        $exitCode = Invoke-RemoteSsh -Interactive -RemoteCommand $remoteCmd
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds

        $delay = $ReconnectDelaySeconds
        if ($elapsed -lt 10) {
            $rapidFailures += 1
        } else {
            $rapidFailures = 0
        }

        if ($rapidFailures -ge 2) {
            $maxPow = [Math]::Min(5, $rapidFailures - 1)
            $expDelay = [int]([Math]::Min(60, $ReconnectDelaySeconds * [Math]::Pow(2, $maxPow)))
            if ($delay -lt $expDelay) {
                $delay = $expDelay
            }
        }

        if ($exitCode -ne 0) {
            Write-Host "remote launcher exited with code $exitCode."
        }
        if ($exitCode -eq 255) {
            Write-Host "ssh transport failed (exit 255). check sshd/firewall/fail2ban/network reachability."
            if ($delay -lt 10) {
                $delay = 10
            }
        }
        if ($rapidFailures -ge 3) {
            Write-Host "remote session is exiting quickly repeatedly. check remote tmux/codex startup state."
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

Show-Banner
Ensure-WindowsOpenSsh
Ensure-Codex
Select-SshBackend
Ensure-QuicLocalProxy
Ensure-NcatForProxy
Ensure-PuttyHostKeyCached
Write-TempSshConfig
Test-RemotePrereqs

if (-not $NoSyncAuth) {
    Sync-LocalCodexAuthToRemote
}

Start-ReconnectLoop

