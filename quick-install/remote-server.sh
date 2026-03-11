#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-/usr/local/bin/codex-vps}"
REPO_OWNER="morrowshore"
REPO_NAME="sticky-codex"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

download_with_retry() {
  local url="$1"
  local out_file="$2"
  local attempts=6
  local attempt delay

  for attempt in $(seq 1 "$attempts"); do
    if curl -fL --connect-timeout 20 --max-time 300 "$url" -o "$out_file"; then
      return 0
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      delay=$(( attempt * 4 ))
      if [ "$delay" -gt 30 ]; then
        delay=30
      fi
      echo "download failed (attempt $attempt/$attempts). retrying in $delay seconds..." >&2
      sleep "$delay"
    fi
  done

  return 1
}

prompt_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local answer=""

  if [ -n "$default_value" ]; then
    read -r -p "$prompt_text [$default_value]: " answer
    if [ -z "$answer" ]; then
      printf '%s\n' "$default_value"
      return
    fi
    printf '%s\n' "$answer"
    return
  fi

  read -r -p "$prompt_text: " answer
  printf '%s\n' "$answer"
}

prompt_required() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local answer=""

  while true; do
    answer="$(prompt_with_default "$prompt_text" "$default_value")"
    if [ -n "$answer" ]; then
      printf '%s\n' "$answer"
      return
    fi
    echo "value is required." >&2
  done
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

parse_proxy_spec() {
  local spec="$1"
  local host port user pass extra

  IFS=':' read -r host port user pass extra <<EOF
$spec
EOF

  if [ -z "$host" ] || [ -z "$port" ]; then
    echo "invalid proxy spec. expected host:port or host:port:username:password" >&2
    exit 1
  fi

  if [ -n "$extra" ] || { [ -n "$user" ] && [ -z "$pass" ]; }; then
    echo "invalid proxy spec. expected host:port or host:port:username:password" >&2
    exit 1
  fi

  UPSTREAM_HOST="$host"
  UPSTREAM_PORT="$port"
  UPSTREAM_USER="${user:-}"
  UPSTREAM_PASS="${pass:-}"
}

install_sing_box_server() {
  local arch api_url asset_url temp_dir archive_path extracted_bin install_path

  if has_command sing-box; then
    printf '%s\n' "$(command -v sing-box)"
    return
  fi

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "unsupported architecture for automatic sing-box install: $arch" >&2
      exit 1
      ;;
  esac

  api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  asset_url="$(curl -fsSL "$api_url" | grep '"browser_download_url"' | cut -d '"' -f 4 | grep "linux-$arch.tar.gz" | head -n1 || true)"
  if [ -z "$asset_url" ]; then
    echo "could not find sing-box release asset for linux-$arch." >&2
    exit 1
  fi

  temp_dir="$(mktemp -d)"
  archive_path="$temp_dir/sing-box.tar.gz"
  if ! download_with_retry "$asset_url" "$archive_path"; then
    rm -rf "$temp_dir"
    echo "failed to download sing-box package." >&2
    exit 1
  fi

  if ! tar -xzf "$archive_path" -C "$temp_dir"; then
    rm -rf "$temp_dir"
    echo "failed to extract sing-box package." >&2
    exit 1
  fi

  extracted_bin="$(find "$temp_dir" -type f -name sing-box | head -n1 || true)"
  if [ -z "$extracted_bin" ]; then
    rm -rf "$temp_dir"
    echo "sing-box binary was not found in extracted package." >&2
    exit 1
  fi

  install_path="/usr/local/bin/sing-box"
  if [ -w "/usr/local/bin" ]; then
    install -m 755 "$extracted_bin" "$install_path"
  else
    sudo mkdir -p /usr/local/bin
    sudo install -m 755 "$extracted_bin" "$install_path"
  fi
  rm -rf "$temp_dir"

  printf '%s\n' "$install_path"
}

configure_wss_server_if_selected() {
  local choice wss_port wss_password wss_sni upstream_mode upstream_spec
  local previous_wss_password
  local config_dir cert_path key_path config_path service_path singbox_bin
  local cert_tmp key_tmp
  local outbound_block final_tag escaped_pass escaped_sni escaped_host escaped_user escaped_proxy_pass singbox_upstream_type
  local host_hint

  if [ ! -t 0 ]; then
    return
  fi

  choice="$(prompt_with_default "set up WSS stability proxy server now? (Y/n)" "Y")"
  case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      ;;
    *)
      return
      ;;
  esac

  config_dir="/etc/sticky-codex/wss"
  cert_path="$config_dir/server.crt"
  key_path="$config_dir/server.key"
  config_path="$config_dir/sing-box-server.json"
  service_path="/etc/systemd/system/sticky-codex-wss.service"

  previous_wss_password=""
  if sudo test -f "$config_path"; then
    previous_wss_password="$(sudo sed -n 's/.*"users".*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config_path" | head -n1 || true)"
  fi

  wss_port="$(prompt_with_default "wss listen port" "13131")"
  case "$wss_port" in
    ''|*[!0-9]*)
      echo "wss listen port must be numeric (1-65535)." >&2
      exit 1
      ;;
  esac
  if [ "$wss_port" -lt 1 ] || [ "$wss_port" -gt 65535 ]; then
    echo "wss listen port must be in range 1-65535." >&2
    exit 1
  fi
  if [ -n "$previous_wss_password" ]; then
    read -r -s -p "wss password (stored in profile) [previous password]: " wss_password
    printf '\n'
    if [ -z "$wss_password" ]; then
      wss_password="$previous_wss_password"
    fi
  else
    read -r -s -p "wss password (stored in profile): " wss_password
    printf '\n'
  fi
  if [ -z "$wss_password" ]; then
    echo "wss password is required." >&2
    exit 1
  fi
  wss_sni="$(prompt_with_default "tls sni/common-name for certificate" "sticky-codex.local")"

  while true; do
    upstream_mode="$(prompt_with_default "upstream proxy mode [no]  no/socks5/http" "no")"
    upstream_mode="$(printf '%s' "$upstream_mode" | tr '[:upper:]' '[:lower:]')"
    case "$upstream_mode" in
      no|socks5|http)
        break
        ;;
      *)
        echo "please enter no, socks5, or http." >&2
        ;;
    esac
  done

  if [ "$upstream_mode" != "no" ]; then
    upstream_spec="$(prompt_required "upstream proxy address (host:port or host:port:username:password)" "")"
    parse_proxy_spec "$upstream_spec"
  fi

  singbox_bin="$(install_sing_box_server)"
  sudo mkdir -p "$config_dir"

  if ! has_command openssl; then
    echo "openssl is missing. attempting to install..."
    if has_command apt-get; then
      sudo apt-get update || true
      sudo apt-get install -y openssl || true
    elif has_command dnf; then
      sudo dnf install -y openssl || true
    elif has_command yum; then
      sudo yum install -y openssl || true
    elif has_command pacman; then
      sudo pacman -Sy --noconfirm openssl || true
    elif has_command zypper; then
      sudo zypper --non-interactive install openssl || true
    elif has_command apk; then
      sudo apk add openssl || true
    fi
  fi
  if ! has_command openssl; then
    echo "openssl is required for WSS certificate generation." >&2
    exit 1
  fi

  cert_tmp="$(mktemp)"
  key_tmp="$(mktemp)"
  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$wss_sni" \
    -keyout "$key_tmp" \
    -out "$cert_tmp" >/dev/null 2>&1; then
    rm -f "$cert_tmp" "$key_tmp"
    echo "failed to generate WSS certificate/key pair with openssl." >&2
    exit 1
  fi
  sudo install -m 600 "$key_tmp" "$key_path"
  sudo install -m 644 "$cert_tmp" "$cert_path"
  rm -f "$cert_tmp" "$key_tmp"

  escaped_sni="$(json_escape "$wss_sni")"
  escaped_pass="$(json_escape "$wss_password")"
  outbound_block='{"type":"direct","tag":"direct"}'
  final_tag="direct"
  if [ "$upstream_mode" = "socks5" ] || [ "$upstream_mode" = "http" ]; then
    escaped_host="$(json_escape "$UPSTREAM_HOST")"
    escaped_user="$(json_escape "$UPSTREAM_USER")"
    escaped_proxy_pass="$(json_escape "$UPSTREAM_PASS")"
    if [ "$upstream_mode" = "socks5" ]; then
      singbox_upstream_type="socks"
    else
      singbox_upstream_type="http"
    fi
    if [ -n "$UPSTREAM_USER" ]; then
      outbound_block="{\"type\":\"$singbox_upstream_type\",\"tag\":\"upstream\",\"server\":\"$escaped_host\",\"server_port\":$UPSTREAM_PORT,\"username\":\"$escaped_user\",\"password\":\"$escaped_proxy_pass\"}"
    else
      outbound_block="{\"type\":\"$singbox_upstream_type\",\"tag\":\"upstream\",\"server\":\"$escaped_host\",\"server_port\":$UPSTREAM_PORT}"
    fi
    final_tag="upstream"
  fi

  sudo tee "$config_path" >/dev/null <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "wss-in",
      "listen": "::",
      "listen_port": $wss_port,
      "users": [ { "name": "sticky-codex", "password": "$escaped_pass" } ],
      "tls": {
        "enabled": true,
        "server_name": "$escaped_sni",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      },
      "transport": {
        "type": "ws",
        "path": "/sticky-codex"
      }
    }
  ],
  "outbounds": [
    $outbound_block
  ],
  "route": { "final": "$final_tag" }
}
EOF

  sudo tee "$service_path" >/dev/null <<EOF
[Unit]
Description=Sticky Codex WSS Stability Proxy (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$singbox_bin run -c $config_path
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  if ! "$singbox_bin" check -c "$config_path" >/dev/null 2>&1; then
    echo "generated WSS sing-box config failed validation:" >&2
    "$singbox_bin" check -c "$config_path" >&2 || true
    exit 1
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable sticky-codex-wss.service >/dev/null 2>&1 || true
  if ! sudo systemctl restart sticky-codex-wss.service; then
    echo "failed to restart sticky-codex-wss.service." >&2
    sudo journalctl -u sticky-codex-wss.service --no-pager -n 80 >&2 || true
    exit 1
  fi
  if ! sudo systemctl is-active --quiet sticky-codex-wss.service; then
    echo "sticky-codex-wss.service is not active after restart." >&2
    sudo systemctl status sticky-codex-wss.service --no-pager -n 80 >&2 || true
    exit 1
  fi

  host_hint="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [ -z "$host_hint" ]; then
    host_hint="$(hostname)"
  fi

  echo
  echo "WSS stability proxy server is configured and running (service: sticky-codex-wss)."
  echo "client values:"
  echo "  proxy type: wss"
  echo "  wss server host: $host_hint"
  echo "  wss server port: $wss_port"
  echo "  wss password: (the value you entered or previously set)"
  echo "  wss tls sni: $wss_sni"
  echo "  wss path: /sticky-codex"
  if [ "$upstream_mode" != "no" ]; then
    echo "  upstream mode: $upstream_mode"
    echo "  upstream target: $UPSTREAM_HOST:$UPSTREAM_PORT"
  fi
}

download_launcher() {
  local rel_path="remote-server/codex-vps.sh"
  local base="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME"

  if download_with_retry "$base/main/$rel_path" "$TMP_FILE"; then
    return
  fi

  if download_with_retry "$base/master/$rel_path" "$TMP_FILE"; then
    return
  fi

  echo "failed to download $rel_path from main or master branch." >&2
  echo "if this persists, verify repo owner/name and branch in this installer." >&2
  exit 1
}

install_launcher() {
  local target_di
  target_dir="$(dirname "$TARGET")"

  if [ -d "$target_dir" ] && [ -w "$target_dir" ]; then
    install -m 755 "$TMP_FILE" "$TARGET"
  else
    sudo mkdir -p "$target_dir"
    sudo install -m 755 "$TMP_FILE" "$TARGET"
  fi
}

install_codex_cli_server() {
  local attempt delay
  local codex_path

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

  link_codex_if_needed() {
    local candidate="$1"
    add_npm_path
    if has_command codex; then
      return 0
    fi
    if [ -w /usr/local/bin ]; then
      ln -sf "$candidate" /usr/local/bin/codex || true
    else
      sudo ln -sf "$candidate" /usr/local/bin/codex || true
    fi
    add_npm_path
    has_command codex
  }

  install_codex_package() {
    npm install -g @openai/codex && return 0
    npm install --location=global @openai/codex && return 0
    return 1
  }

  if ! has_command npm; then
    echo "npm is missing. attempting to install nodejs and npm..."
    if has_command apt-get; then
      sudo apt-get update || true
      sudo apt-get install -y nodejs npm || true
    elif has_command dnf; then
      sudo dnf install -y nodejs npm || true
    elif has_command yum; then
      sudo yum install -y nodejs npm || true
    elif has_command pacman; then
      sudo pacman -Sy --noconfirm nodejs npm || true
    elif has_command zypper; then
      sudo zypper --non-interactive install nodejs npm || true
    elif has_command apk; then
      sudo apk add nodejs npm || true
    fi
  fi

  if ! has_command npm; then
    echo "npm is still missing after install attempts." >&2
    return 1
  fi

  for attempt in 1 2 3 4 5; do
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
      echo "codex npm install failed (attempt $attempt/5). retrying in $delay seconds..." >&2
      sleep "$delay"
    fi
  done

  codex_path="$(find_codex_bin || true)"
  if [ -z "$codex_path" ]; then
    return 1
  fi

  if ! link_codex_if_needed "$codex_path"; then
    return 1
  fi

  if ! codex --version >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

prompt_install_codex_if_missing() {
  local choice

  if has_command codex; then
    return
  fi

  if [ ! -t 0 ]; then
    echo "codex is missing on this server. run later: npm install -g @openai/codex" >&2
    return
  fi

  choice="$(prompt_with_default "codex cli is missing on this server. install now? (Y/n)" "Y")"
  case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      echo "skipped codex install."
      ;;
    *)
      if install_codex_cli_server && has_command codex; then
        echo "codex installed successfully."
      else
        echo "automatic codex install failed. you can run: npm install -g @openai/codex" >&2
      fi
      ;;
  esac
}

choose_install_target() {
  local choice

  if [ $# -ne 0 ] || [ ! -t 0 ]; then
    return
  fi

  while true; do
    choice="$(prompt_with_default "install location (default/here)" "default")"
    case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
      default)
        return
        ;;
      here)
        TARGET="$(pwd)/codex-vps"
        return
        ;;
      *)
        echo "please enter default or here." >&2
        ;;
    esac
  done
}

choose_install_target "$@"
download_launcher
install_launcher
printf 'installed %s\n' "$TARGET"
configure_wss_server_if_selected
prompt_install_codex_if_missing
