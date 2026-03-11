#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-/usr/local/bin/codex-remote}"
PROFILE_FILE="${CODEX_REMOTE_PROFILE:-$HOME/.config/sticky-codex/connection.env}"
REPO_OWNER="morrowshore"
REPO_NAME="sticky-codex"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT
RULE='------------------------------------------------------------'

HOST_ALIAS=""
HOST_NAME=""
USER_NAME=""
PORT="22"
IDENTITY_FILE=""
REMOTE_PROJECT_DIR=""
SESSION_NAME=""
IDLE_DAYS="7"
RECONNECT_DELAY_SECONDS="3"
SYNC_AUTH="1"
REMOTE_SCRIPT="/usr/local/bin/codex-vps"
AUTH_MODE="auto"
PASSWORD=""
PROXY_TYPE="no"
PROXY_SPEC=""
QUIC_SERVER=""
QUIC_PORT="61313"
QUIC_PASSWORD=""
QUIC_SNI=""
QUIC_LOCAL_SOCKS_PORT="10809"
QUIC_UPSTREAM_TYPE="no"
QUIC_UPSTREAM_SPEC=""

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

download_launcher() {
  local rel_path="linux-client/codex-remote.sh"
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

trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

read_profile_value() {
  local file_path="$1"
  local wanted_key="$2"

  [ -f "$file_path" ] || return 0

  while IFS='=' read -r raw_key raw_value; do
    local key value
    key="$(trim "$raw_key")"
    value="$(trim "${raw_value:-}")"

    [ -z "$key" ] && continue
    case "$key" in
      \#*)
        continue
        ;;
    esac

    if [ "$key" = "$wanted_key" ]; then
      if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
        value="${value#\"}"
        value="${value%\"}"
      fi
      printf '%s\n' "$value"
      return 0
    fi
  done < "$file_path"
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
  local default_value="$2"

  while true; do
    local value
    value="$(prompt_with_default "$prompt_text" "$default_value")"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return
    fi
    echo "value is required." >&2
  done
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
        TARGET="$(pwd)/codex-remote"
        return
        ;;
      *)
        echo "please enter default or here." >&2
        ;;
    esac
  done
}

normalize_auth_mode() {
  local mode
  mode="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$mode" in
    auto|key|password)
      printf '%s\n' "$mode"
      ;;
    *)
      echo "auto"
      ;;
  esac
}

encode_base64() {
  local input="$1"
  if [ -z "$input" ]; then
    printf '\n'
    return
  fi

  printf '%s' "$input" | base64 | tr -d '\n'
  printf '\n'
}

decode_base64() {
  local input="$1"
  if [ -z "$input" ]; then
    printf '\n'
    return
  fi

  if printf '%s' "$input" | base64 -d >/dev/null 2>&1; then
    printf '%s' "$input" | base64 -d
    return
  fi

  if printf '%s' "$input" | base64 --decode >/dev/null 2>&1; then
    printf '%s' "$input" | base64 --decode
    return
  fi

  printf '\n'
}

quote_env_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_profile() {
  local profile_di
  profile_dir="$(dirname "$PROFILE_FILE")"
  mkdir -p "$profile_dir"
  chmod 700 "$profile_dir" 2>/dev/null || true

  {
    printf '# sticky-codex connection profile\n'
    printf 'HOST_ALIAS="%s"\n' "$(quote_env_value "$HOST_ALIAS")"
    printf 'HOST_NAME="%s"\n' "$(quote_env_value "$HOST_NAME")"
    printf 'USER_NAME="%s"\n' "$(quote_env_value "$USER_NAME")"
    printf 'PORT="%s"\n' "$(quote_env_value "$PORT")"
    printf 'IDENTITY_FILE="%s"\n' "$(quote_env_value "$IDENTITY_FILE")"
    printf 'REMOTE_PROJECT_DIR="%s"\n' "$(quote_env_value "$REMOTE_PROJECT_DIR")"
    printf 'SESSION_NAME="%s"\n' "$(quote_env_value "$SESSION_NAME")"
    printf 'IDLE_DAYS="%s"\n' "$(quote_env_value "$IDLE_DAYS")"
    printf 'RECONNECT_DELAY_SECONDS="%s"\n' "$(quote_env_value "$RECONNECT_DELAY_SECONDS")"
    printf 'SYNC_AUTH="%s"\n' "$(quote_env_value "$SYNC_AUTH")"
    printf 'REMOTE_SCRIPT="%s"\n' "$(quote_env_value "$REMOTE_SCRIPT")"
    printf 'AUTH_MODE="%s"\n' "$(quote_env_value "$AUTH_MODE")"
    printf 'PASSWORD_B64="%s"\n' "$(quote_env_value "$(encode_base64 "$PASSWORD")")"
    printf 'PROXY_TYPE="%s"\n' "$(quote_env_value "$PROXY_TYPE")"
    printf 'PROXY_SPEC="%s"\n' "$(quote_env_value "$PROXY_SPEC")"
    printf 'QUIC_SERVER="%s"\n' "$(quote_env_value "$QUIC_SERVER")"
    printf 'QUIC_PORT="%s"\n' "$(quote_env_value "$QUIC_PORT")"
    printf 'QUIC_PASSWORD_B64="%s"\n' "$(quote_env_value "$(encode_base64 "$QUIC_PASSWORD")")"
    printf 'QUIC_SNI="%s"\n' "$(quote_env_value "$QUIC_SNI")"
    printf 'QUIC_LOCAL_SOCKS_PORT="%s"\n' "$(quote_env_value "$QUIC_LOCAL_SOCKS_PORT")"
    printf 'QUIC_UPSTREAM_TYPE="%s"\n' "$(quote_env_value "$QUIC_UPSTREAM_TYPE")"
    printf 'QUIC_UPSTREAM_SPEC="%s"\n' "$(quote_env_value "$QUIC_UPSTREAM_SPEC")"
    printf 'PASSWORD=""\n'
  } > "$PROFILE_FILE"

  chmod 600 "$PROFILE_FILE" 2>/dev/null || true
}

collect_profile_inputs() {
  printf '%s\n' "$RULE"
  printf 'remote connection setup\n'
  printf '%s\n' "$RULE"
  HOST_ALIAS="$(prompt_with_default "host alias" "$HOST_ALIAS")"
  HOST_NAME="$(prompt_required "remote host (ip or domain)" "$HOST_NAME")"
  USER_NAME="$(prompt_required "remote user" "${USER_NAME:-root}")"
  PORT="$(prompt_with_default "ssh port" "$PORT")"
  REMOTE_PROJECT_DIR="$(prompt_required "remote project directory" "$REMOTE_PROJECT_DIR")"
  SESSION_NAME="$(prompt_with_default "session name (blank for auto)" "$SESSION_NAME")"
  IDLE_DAYS="$(prompt_with_default "idle days before stale session cleanup" "$IDLE_DAYS")"
  RECONNECT_DELAY_SECONDS="$(prompt_with_default "reconnect delay seconds" "$RECONNECT_DELAY_SECONDS")"

  AUTH_MODE="$(normalize_auth_mode "$(prompt_with_default "ssh auth mode (auto/key/password)" "$AUTH_MODE")")"

  if [ "$AUTH_MODE" = "key" ] || [ "$AUTH_MODE" = "auto" ]; then
    IDENTITY_FILE="$(prompt_with_default "ssh identity file path (optional)" "$IDENTITY_FILE")"
  else
    IDENTITY_FILE=""
  fi

  if [ "$AUTH_MODE" = "password" ]; then
    if [ -n "$PASSWORD" ]; then
      read -r -s -p "ssh password (stored in profile) [previous password]: " PASSWORD_INPUT
      printf '\n'
      if [ -n "$PASSWORD_INPUT" ]; then
        PASSWORD="$PASSWORD_INPUT"
      fi
    else
      read -r -s -p "ssh password (stored in profile): " PASSWORD
      printf '\n'
    fi
    unset PASSWORD_INPUT
  else
    PASSWORD=""
  fi

  local sync_choice
  sync_choice="$(prompt_with_default "sync local Codex auth.json before attach? (Y/n)" "Y")"
  case "$(printf '%s' "$sync_choice" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      SYNC_AUTH="0"
      ;;
    *)
      SYNC_AUTH="1"
      ;;
  esac

  if [ "$SYNC_AUTH" = "1" ]; then
    printf 'tip: choose manual if you have already done codex login setup.\n'
  fi

  local upstream_default upstream_type upstream_spec use_quic_choice
  upstream_default="no"
  if [ "$PROXY_TYPE" = "socks5" ] || [ "$PROXY_TYPE" = "http" ]; then
    upstream_default="$PROXY_TYPE"
  elif { [ "$PROXY_TYPE" = "quic" ] || [ "$PROXY_TYPE" = "wss" ]; } && { [ "$QUIC_UPSTREAM_TYPE" = "no" ] || [ "$QUIC_UPSTREAM_TYPE" = "socks5" ] || [ "$QUIC_UPSTREAM_TYPE" = "http" ]; }; then
    upstream_default="$QUIC_UPSTREAM_TYPE"
  fi

  while true; do
    upstream_type="$(prompt_with_default "Use upstream proxy? [no]  no/socks5/http" "$upstream_default")"
    upstream_type="$(printf '%s' "$upstream_type" | tr '[:upper:]' '[:lower:]')"
    case "$upstream_type" in
      no|socks5|http)
        break
        ;;
      *)
        echo "please enter no, socks5, or http." >&2
        ;;
    esac
  done

  upstream_spec=""
  if [ "$upstream_type" = "socks5" ] || [ "$upstream_type" = "http" ]; then
    local upstream_spec_default
    upstream_spec_default="$PROXY_SPEC"
    if [ "$PROXY_TYPE" = "quic" ] || [ "$PROXY_TYPE" = "wss" ]; then
      upstream_spec_default="$QUIC_UPSTREAM_SPEC"
    fi
    upstream_spec="$(prompt_required "upstream proxy address (host:port or host:port:username:password)" "$upstream_spec_default")"
  fi

  while true; do
    use_quic_choice="$(prompt_with_default "Use wss stability layer? [n] y/n" "n")"
    use_quic_choice="$(printf '%s' "$use_quic_choice" | tr '[:upper:]' '[:lower:]')"
    case "$use_quic_choice" in
      y|yes|n|no)
        break
        ;;
      *)
        echo "please enter y or n." >&2
        ;;
    esac
  done

  if [ "$use_quic_choice" = "y" ] || [ "$use_quic_choice" = "yes" ]; then
    PROXY_TYPE="wss"
    QUIC_SERVER="$(prompt_with_default "wss server host" "${QUIC_SERVER:-$HOST_NAME}")"
    if [ -z "${QUIC_PORT:-}" ] || [ "$QUIC_PORT" = "61313" ]; then
      QUIC_PORT="13131"
    fi
    QUIC_PORT="$(prompt_with_default "wss server port" "${QUIC_PORT:-13131}")"
    if [ -n "${QUIC_PASSWORD:-}" ]; then
      read -r -s -p "wss password (stored in profile) [previous password]: " QUIC_PASSWORD_INPUT
      printf '\n'
      if [ -n "$QUIC_PASSWORD_INPUT" ]; then
        QUIC_PASSWORD="$QUIC_PASSWORD_INPUT"
      fi
    else
      read -r -s -p "wss password (stored in profile): " QUIC_PASSWORD
      printf '\n'
    fi
    unset QUIC_PASSWORD_INPUT
    QUIC_SNI="$(prompt_with_default "wss tls sni (blank=server host)" "${QUIC_SNI:-$QUIC_SERVER}")"
    local wss_local_default
    wss_local_default="${QUIC_LOCAL_SOCKS_PORT:-10809}"
    if [ "$wss_local_default" = "10809" ]; then
      wss_local_default="10819"
    fi
    QUIC_LOCAL_SOCKS_PORT="$(prompt_with_default "local socks port for wss tunnel" "$wss_local_default")"
    QUIC_UPSTREAM_TYPE="$upstream_type"
    QUIC_UPSTREAM_SPEC="$upstream_spec"
    PROXY_SPEC=""
  else
    PROXY_TYPE="$upstream_type"
    PROXY_SPEC="$upstream_spec"
    QUIC_SERVER=""
    QUIC_PORT=""
    QUIC_PASSWORD=""
    QUIC_SNI=""
    QUIC_LOCAL_SOCKS_PORT=""
    QUIC_UPSTREAM_TYPE="no"
    QUIC_UPSTREAM_SPEC=""
  fi

  write_profile
  printf 'saved connection profile: %s\n' "$PROFILE_FILE"
}

load_defaults_from_existing_profile() {
  HOST_ALIAS="$(read_profile_value "$PROFILE_FILE" HOST_ALIAS)"
  HOST_NAME="$(read_profile_value "$PROFILE_FILE" HOST_NAME)"
  USER_NAME="$(read_profile_value "$PROFILE_FILE" USER_NAME)"
  PORT="$(read_profile_value "$PROFILE_FILE" PORT)"
  IDENTITY_FILE="$(read_profile_value "$PROFILE_FILE" IDENTITY_FILE)"
  REMOTE_PROJECT_DIR="$(read_profile_value "$PROFILE_FILE" REMOTE_PROJECT_DIR)"
  SESSION_NAME="$(read_profile_value "$PROFILE_FILE" SESSION_NAME)"
  IDLE_DAYS="$(read_profile_value "$PROFILE_FILE" IDLE_DAYS)"
  RECONNECT_DELAY_SECONDS="$(read_profile_value "$PROFILE_FILE" RECONNECT_DELAY_SECONDS)"
  SYNC_AUTH="$(read_profile_value "$PROFILE_FILE" SYNC_AUTH)"
  REMOTE_SCRIPT="$(read_profile_value "$PROFILE_FILE" REMOTE_SCRIPT)"
  AUTH_MODE="$(read_profile_value "$PROFILE_FILE" AUTH_MODE)"
  PASSWORD_B64="$(read_profile_value "$PROFILE_FILE" PASSWORD_B64)"
  PASSWORD="$(decode_base64 "$PASSWORD_B64")"
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(read_profile_value "$PROFILE_FILE" PASSWORD)"
  fi
  PROXY_TYPE="$(read_profile_value "$PROFILE_FILE" PROXY_TYPE)"
  PROXY_SPEC="$(read_profile_value "$PROFILE_FILE" PROXY_SPEC)"
  QUIC_SERVER="$(read_profile_value "$PROFILE_FILE" QUIC_SERVER)"
  QUIC_PORT="$(read_profile_value "$PROFILE_FILE" QUIC_PORT)"
  QUIC_PASSWORD_B64="$(read_profile_value "$PROFILE_FILE" QUIC_PASSWORD_B64)"
  QUIC_PASSWORD="$(decode_base64 "$QUIC_PASSWORD_B64")"
  [ -n "$QUIC_PASSWORD" ] || QUIC_PASSWORD="$(read_profile_value "$PROFILE_FILE" QUIC_PASSWORD)"
  QUIC_SNI="$(read_profile_value "$PROFILE_FILE" QUIC_SNI)"
  QUIC_LOCAL_SOCKS_PORT="$(read_profile_value "$PROFILE_FILE" QUIC_LOCAL_SOCKS_PORT)"
  QUIC_UPSTREAM_TYPE="$(read_profile_value "$PROFILE_FILE" QUIC_UPSTREAM_TYPE)"
  QUIC_UPSTREAM_SPEC="$(read_profile_value "$PROFILE_FILE" QUIC_UPSTREAM_SPEC)"

  [ -n "$HOST_ALIAS" ] || HOST_ALIAS="myvps"
  [ -n "$PORT" ] || PORT="22"
  [ -n "$IDLE_DAYS" ] || IDLE_DAYS="7"
  [ -n "$RECONNECT_DELAY_SECONDS" ] || RECONNECT_DELAY_SECONDS="3"
  [ -n "$SYNC_AUTH" ] || SYNC_AUTH="1"
  [ -n "$REMOTE_SCRIPT" ] || REMOTE_SCRIPT="/usr/local/bin/codex-vps"
  [ -n "$AUTH_MODE" ] || AUTH_MODE="auto"
  [ -n "$PROXY_TYPE" ] || PROXY_TYPE="no"
  if [ -z "$QUIC_PORT" ]; then
    if [ "$PROXY_TYPE" = "wss" ]; then
      QUIC_PORT="13131"
    else
      QUIC_PORT="61313"
    fi
  elif [ "$PROXY_TYPE" = "wss" ] && [ "$QUIC_PORT" = "61313" ]; then
    QUIC_PORT="13131"
  fi
  [ -n "$QUIC_LOCAL_SOCKS_PORT" ] || QUIC_LOCAL_SOCKS_PORT="10809"
  if [ "$PROXY_TYPE" = "wss" ] && [ "$QUIC_LOCAL_SOCKS_PORT" = "10809" ]; then
    QUIC_LOCAL_SOCKS_PORT="10819"
  fi
  [ -n "$QUIC_UPSTREAM_TYPE" ] || QUIC_UPSTREAM_TYPE="no"
}

choose_install_target "$@"
download_launcher
install_launcher
printf 'installed %s\n' "$TARGET"

if [ -t 0 ]; then
  load_defaults_from_existing_profile
  collect_profile_inputs
else
  printf 'non-interactive shell detected; skipped profile setup.\n'
fi

printf '\n'
printf '%s\n' "$RULE"
printf 'codex auth setup\n'
printf '%s\n' "$RULE"
printf 'put this in ~/.codex/config.toml:\n\n'
printf '```toml\n'
printf 'cli_auth_credentials_store = "file"\n'
printf '```\n\n'
printf 'then run:\n\n'
printf '  codex login\n\n'
printf 'why: sticky-codex syncs auth.json to the remote server before attach, and Codex only writes auth.json when file-based auth storage is enabled.\n'
printf '\n'
printf '%s\n' "$RULE"
printf 'how to run after setup\n'
printf '%s\n' "$RULE"
printf 'option 1 (direct command):\n\n'
printf '  %s\n\n' "$TARGET"
printf 'option 2 (from install directory):\n\n'
printf '  cd %s\n' "$(dirname "$TARGET")"
printf '  ./%s\n\n' "$(basename "$TARGET")"
printf 'one-run override command (flags win over profile):\n\n'
printf '  %s --host-name your.vps.host --user-name root --remote-project-dir /srv/project\n\n' "$TARGET"
printf 'note: if %s is missing later, overrides are required (--host-name, --user-name, --remote-project-dir).\n' "$PROFILE_FILE"
printf '%s\n' "$RULE"
