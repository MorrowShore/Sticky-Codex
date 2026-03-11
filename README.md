# Sticky Codex

Sticky Codex keeps a Codex CLI session alive on a remote Linux server through `tmux`, while local launchers handle reconnect loops for Windows and Linux, all to prevent interruption during even the worst internet instabilities.

design goals:
- reconnect quickly after SSH disconnects
- recover the same terminal and remote Codex session instead of starting over
- clean up stale sessions automatically after long idle periods
- practical, easy to use, small


The project is licensed under the AGPL-3.0 license.

Support: https://morrowshore.com

## Quick install

These scripts download the launchers and then prompt for remote destination/auth values, proxy settings, and install location (`default`/`here`). Client installers write a reusable connection profile so later runs can start with no flags.

download resilience:
- quick-install scripts use higher network timeouts plus retry/backoff before failing.
- runtime dependency fetches (PuTTY/Nmap on Windows) also retry before fatal errors.
- Windows runtime install failures now print a diagnosis (`network`, `winget-unavailable`, `policy-or-permission`, `winget-source`) plus winget output tail.
- launchers now prompt to install missing `codex` and missing stability core (`sing-box`) when needed.

### remote Linux server

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/morrowshore/sticky-codex/main/quick-install/remote-server.sh || curl -fsSL https://raw.githubusercontent.com/morrowshore/sticky-codex/master/quick-install/remote-server.sh)
```

installs `codex-vps` to `/usr/local/bin/codex-vps` by default.
If you choose it during install, it also auto-installs a WSS stability proxy server (`sing-box` + systemd service) and can chain it through an upstream `socks5` or `http` proxy.

### Windows client

If you are in PowerShell, run:

```powershell
$u='https://raw.githubusercontent.com/morrowshore/sticky-codex/main/quick-install/windows-client.ps1'; $m='https://raw.githubusercontent.com/morrowshore/sticky-codex/master/quick-install/windows-client.ps1'; try { Invoke-RestMethod $u -UseBasicParsing | Invoke-Expression } catch { Invoke-RestMethod $m -UseBasicParsing | Invoke-Expression }
```

If you are in `cmd.exe`, run:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/morrowshore/sticky-codex/main/quick-install/windows-client.ps1'; $m='https://raw.githubusercontent.com/morrowshore/sticky-codex/master/quick-install/windows-client.ps1'; try { Invoke-RestMethod $u -UseBasicParsing | Invoke-Expression } catch { Invoke-RestMethod $m -UseBasicParsing | Invoke-Expression }"
```

installs `%LOCALAPPDATA%\sticky-codex\codex-remote.ps1`.

### Linux client

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/morrowshore/sticky-codex/main/quick-install/linux-client.sh || curl -fsSL https://raw.githubusercontent.com/morrowshore/sticky-codex/master/quick-install/linux-client.sh)
```

installs `/usr/local/bin/codex-remote`.

### profile file written by client installers

- Linux default: `~/.config/sticky-codex/connection.env`
- Windows default: `%LOCALAPPDATA%\sticky-codex\connection.env`

The launcher loads this file automatically and only prompts if required values are still missing.

### required Codex config on client machine

Put this in your local Codex config:

```toml
cli_auth_credentials_store = "file"
```

Then run:

```bash
codex login
```

why: sticky-codex syncs local `auth.json` to the server before attach, and Codex only writes that file when file-based credential storage is enabled.

## Manual setup

### 1. remote Linux server

```bash
sudo mkdir -p /usr/local/bin
sudo nano /usr/local/bin/codex-vps
```

paste [`remote-server/codex-vps.sh`](remote-server/codex-vps.sh), then:

```bash
sudo chmod +x /usr/local/bin/codex-vps
```

### 2. Windows client

copy [`windows-client/codex-remote.ps1`](windows-client/codex-remote.ps1) to your Windows machine.

if needed, paste it into `codex-remote.txt`, then rename to `codex-remote.ps1`.

run it:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1
```

or override values in one run:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-remote.ps1 -HostName "your.vps.host" -UserName "youruser" -RemoteProjectDir "/srv/project"
```

### 3. Linux client

```bash
sudo mkdir -p /usr/local/bin
sudo nano /usr/local/bin/codex-remote
```

paste [`linux-client/codex-remote.sh`](linux-client/codex-remote.sh), then:

```bash
sudo chmod +x /usr/local/bin/codex-remote
```

run it:

```bash
/usr/local/bin/codex-remote
```

or override values in one run:

```bash
/usr/local/bin/codex-remote --host-name your.vps.host --user-name youruser --remote-project-dir /srv/project
```

## SSH auth modes

Both client launchers support:
- key auth
- password auth
- auto mode

password-mode reconnect behavior:
- Linux: if password is configured, launcher tries to use `sshpass` for non-interactive reconnects.
- Windows: launcher requires `plink`/`pscp` for non-interactive reconnects. It auto-checks PATH, standard PuTTY install paths, `winget` install, then portable download to `%LOCALAPPDATA%\sticky-codex\tools`.
- both launchers require a saved password value when `auth mode = password`.

proxy mode:
- both client launchers can prompt for `no|socks5|http|quic|wss`
- proxy format is `host:port` or `host:port:username:password`
- proxy routing uses `ncat` via `ProxyCommand` / `-proxycmd`.
- `wss` mode starts a local `sing-box` client and routes SSH through a local SOCKS port over WebSocket+TLS (TCP).
- `wss` mode supports optional upstream proxy chaining (`no|socks5|http`) via `QUIC_UPSTREAM_TYPE` + `QUIC_UPSTREAM_SPEC`.
- default WSS server port is `13131` (valid TCP port range: `1-65535`).
- remote server quick-install can auto-install/configure a WSS proxy server and optional upstream chain (`no|socks5|http`).
- Windows launcher auto-attempts `winget install Insecure.Nmap` (then `Nmap.Nmap` fallback) when proxy is enabled.
- Linux launcher auto-attempts package-manager install for `ncat` when proxy is enabled.

connection resilience:
- keepalive is enabled (`ServerAliveInterval 15`, `ServerAliveCountMax 120`, `TCPKeepAlive yes`) to reduce idle/NAT drops.
- brief internet outages cannot be fully prevented at TCP level, so launcher reconnect logic is the hard guarantee.
