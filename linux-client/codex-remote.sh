#!/usr/bin/env bash
set -euo pipefail

HOST_ALIAS=""
HOST_NAME=""
USER_NAME=""
PORT="22"
IDENTITY_FILE=""
REMOTE_PROJECT_DIR=""
SESSION_NAME=""
IDLE_DAYS="7"
RECONNECT_DELAY_SECONDS="1"
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
PROFILE_FILE="${CODEX_REMOTE_PROFILE:-$HOME/.config/sticky-codex/connection.env}"

HOST_ALIAS_SET="0"
HOST_NAME_SET="0"
USER_NAME_SET="0"
PORT_SET="0"
IDENTITY_FILE_SET="0"
REMOTE_PROJECT_DIR_SET="0"
SESSION_NAME_SET="0"
IDLE_DAYS_SET="0"
RECONNECT_DELAY_SECONDS_SET="0"
SYNC_AUTH_SET="0"
REMOTE_SCRIPT_SET="0"
AUTH_MODE_SET="0"
PASSWORD_SET="0"
PROXY_TYPE_SET="0"
PROXY_SPEC_SET="0"
QUIC_SERVER_SET="0"
QUIC_PORT_SET="0"
QUIC_PASSWORD_SET="0"
QUIC_SNI_SET="0"
QUIC_LOCAL_SOCKS_PORT_SET="0"
QUIC_UPSTREAM_TYPE_SET="0"
QUIC_UPSTREAM_SPEC_SET="0"
PROFILE_FILE_SET="0"

QUIC_SINGBOX_BIN=""
QUIC_PID=""
QUIC_TMP_DIR=""
TUNNEL_SSH_HOST=""

usage() {
  cat <<'EOF'
usage:
  codex-remote.sh --host-name your.vps.host --user-name youruser --remote-project-dir /home/youruser/project [options]

options:
  --host-alias NAME
  --host-name NAME
  --user-name NAME
  --port 22
  --identity-file PATH
  --remote-project-dir PATH
  --session-name NAME
  --idle-days 7
  --reconnect-delay-seconds 1
  --auth-mode auto|key|password
  --password VALUE
  --proxy-type no|socks5|http|wss
    (legacy alias: quic -> wss)
  --proxy-spec host:port[:username:password]
  --quic-server HOST
  --quic-port 61313
  --quic-password VALUE
  --quic-sni HOST
  --quic-local-socks-port 10809
  --quic-upstream-type no|socks5|http
  --quic-upstream-spec host:port[:username:password]
  --profile-file PATH
  --no-sync-auth
  --remote-script /usr/local/bin/codex-vps

examples:
  codex-remote.sh --host-name your.vps.host --user-name youruser --remote-project-dir /srv/project
  codex-remote.sh --host-name your.vps.host --user-name youruser --auth-mode password --remote-project-dir /srv/project
  codex-remote.sh --host-name your.vps.host --user-name youruser --port 2222 --identity-file ~/.ssh/id_ed25519 --remote-project-dir /srv/project
EOF
}

trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

normalize_auth_mode() {
  local mode="$1"
  case "$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')" in
    auto|key|password)
      printf '%s\n' "$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
      ;;
    *)
      echo "invalid auth mode: $mode (expected auto|key|password)" >&2
      exit 1
      ;;
  esac
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

encode_base64() {
  local input="$1"
  if [ -z "$input" ]; then
    printf '\n'
    return
  fi

  printf '%s' "$input" | base64 | tr -d '\n'
  printf '\n'
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

  PROXY_HOST="$host"
  PROXY_PORT="$port"
  PROXY_USER="${user:-}"
  PROXY_PASS="${pass:-}"
}

build_proxy_command() {
  local target_host="$1"
  local target_port="$2"

  if [ "$PROXY_TYPE" = "no" ] || [ -z "$PROXY_SPEC" ]; then
    printf '\n'
    return
  fi

  parse_proxy_spec "$PROXY_SPEC"

  if ! has_command ncat; then
    echo "proxy mode requires ncat in PATH." >&2
    exit 1
  fi

  local type cmd
  if [ "$PROXY_TYPE" = "socks5" ]; then
    type="socks5"
  else
    type="http"
  fi

  cmd="ncat --proxy ${PROXY_HOST}:${PROXY_PORT} --proxy-type ${type} --no-shutdown"
  if [ -n "$PROXY_USER" ]; then
    cmd="$cmd --proxy-auth ${PROXY_USER}:${PROXY_PASS}"
  fi
  cmd="$cmd ${target_host} ${target_port}"

  printf '%s\n' "$cmd"
}

read_profile_value() {
  local wanted_key="$1"

  [ -f "$PROFILE_FILE" ] || return 0

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
  done < "$PROFILE_FILE"
}

load_profile_if_present() {
  [ -f "$PROFILE_FILE" ] || return 0

  if [ "$HOST_ALIAS_SET" = "0" ]; then
    HOST_ALIAS="${HOST_ALIAS:-$(read_profile_value HOST_ALIAS)}"
  fi
  if [ "$HOST_NAME_SET" = "0" ]; then
    HOST_NAME="${HOST_NAME:-$(read_profile_value HOST_NAME)}"
  fi
  if [ "$USER_NAME_SET" = "0" ]; then
    USER_NAME="${USER_NAME:-$(read_profile_value USER_NAME)}"
  fi
  if [ "$PORT_SET" = "0" ]; then
    local profile_port
    profile_port="$(read_profile_value PORT)"
    if [ -n "$profile_port" ]; then
      PORT="$profile_port"
    fi
  fi
  if [ "$IDENTITY_FILE_SET" = "0" ]; then
    IDENTITY_FILE="${IDENTITY_FILE:-$(read_profile_value IDENTITY_FILE)}"
  fi
  if [ "$REMOTE_PROJECT_DIR_SET" = "0" ]; then
    REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-$(read_profile_value REMOTE_PROJECT_DIR)}"
  fi
  if [ "$SESSION_NAME_SET" = "0" ]; then
    SESSION_NAME="${SESSION_NAME:-$(read_profile_value SESSION_NAME)}"
  fi
  if [ "$IDLE_DAYS_SET" = "0" ]; then
    local profile_idle_days
    profile_idle_days="$(read_profile_value IDLE_DAYS)"
    if [ -n "$profile_idle_days" ]; then
      IDLE_DAYS="$profile_idle_days"
    fi
  fi
  if [ "$RECONNECT_DELAY_SECONDS_SET" = "0" ]; then
    local profile_delay
    profile_delay="$(read_profile_value RECONNECT_DELAY_SECONDS)"
    if [ -n "$profile_delay" ]; then
      RECONNECT_DELAY_SECONDS="$profile_delay"
    fi
  fi
  if [ "$REMOTE_SCRIPT_SET" = "0" ]; then
    local profile_remote_script
    profile_remote_script="$(read_profile_value REMOTE_SCRIPT)"
    if [ -n "$profile_remote_script" ]; then
      REMOTE_SCRIPT="$profile_remote_script"
    fi
  fi
  if [ "$AUTH_MODE_SET" = "0" ]; then
    local profile_auth_mode
    profile_auth_mode="$(read_profile_value AUTH_MODE)"
    if [ -n "$profile_auth_mode" ]; then
      AUTH_MODE="$profile_auth_mode"
    fi
  fi
  if [ "$PASSWORD_SET" = "0" ]; then
    local profile_password_b64 profile_password_plain
    profile_password_b64="$(read_profile_value PASSWORD_B64)"
    profile_password_plain="$(decode_base64 "$profile_password_b64")"
    if [ -n "$profile_password_plain" ]; then
      PASSWORD="$profile_password_plain"
    else
      PASSWORD="${PASSWORD:-$(read_profile_value PASSWORD)}"
    fi
  fi
  if [ "$PROXY_TYPE_SET" = "0" ]; then
    local profile_proxy_type
    profile_proxy_type="$(read_profile_value PROXY_TYPE)"
    if [ -n "$profile_proxy_type" ]; then
      PROXY_TYPE="$(printf '%s' "$profile_proxy_type" | tr '[:upper:]' '[:lower:]')"
    fi
  fi
  if [ "$PROXY_SPEC_SET" = "0" ]; then
    PROXY_SPEC="${PROXY_SPEC:-$(read_profile_value PROXY_SPEC)}"
  fi
  if [ "$QUIC_SERVER_SET" = "0" ]; then
    QUIC_SERVER="${QUIC_SERVER:-$(read_profile_value QUIC_SERVER)}"
  fi
  if [ "$QUIC_PORT_SET" = "0" ]; then
    local profile_quic_port
    profile_quic_port="$(read_profile_value QUIC_PORT)"
    if [ -n "$profile_quic_port" ]; then
      QUIC_PORT="$profile_quic_port"
    fi
  fi
  if [ "$QUIC_PASSWORD_SET" = "0" ]; then
    local profile_quic_password_b64 profile_quic_password_plain
    profile_quic_password_b64="$(read_profile_value QUIC_PASSWORD_B64)"
    profile_quic_password_plain="$(decode_base64 "$profile_quic_password_b64")"
    if [ -n "$profile_quic_password_plain" ]; then
      QUIC_PASSWORD="$profile_quic_password_plain"
    else
      QUIC_PASSWORD="${QUIC_PASSWORD:-$(read_profile_value QUIC_PASSWORD)}"
    fi
  fi
  if [ "$QUIC_SNI_SET" = "0" ]; then
    QUIC_SNI="${QUIC_SNI:-$(read_profile_value QUIC_SNI)}"
  fi
  if [ "$QUIC_LOCAL_SOCKS_PORT_SET" = "0" ]; then
    local profile_quic_local_socks_port
    profile_quic_local_socks_port="$(read_profile_value QUIC_LOCAL_SOCKS_PORT)"
    if [ -n "$profile_quic_local_socks_port" ]; then
      QUIC_LOCAL_SOCKS_PORT="$profile_quic_local_socks_port"
    fi
  fi
  if [ "$QUIC_UPSTREAM_TYPE_SET" = "0" ]; then
    local profile_quic_upstream_type
    profile_quic_upstream_type="$(read_profile_value QUIC_UPSTREAM_TYPE)"
    if [ -n "$profile_quic_upstream_type" ]; then
      QUIC_UPSTREAM_TYPE="$(printf '%s' "$profile_quic_upstream_type" | tr '[:upper:]' '[:lower:]')"
    fi
  fi
  if [ "$QUIC_UPSTREAM_SPEC_SET" = "0" ]; then
    QUIC_UPSTREAM_SPEC="${QUIC_UPSTREAM_SPEC:-$(read_profile_value QUIC_UPSTREAM_SPEC)}"
  fi
  if [ "$SYNC_AUTH_SET" = "0" ]; then
    local profile_sync_auth
    profile_sync_auth="$(read_profile_value SYNC_AUTH)"
    case "$profile_sync_auth" in
      0|1)
        SYNC_AUTH="$profile_sync_auth"
        ;;
    esac
  fi
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

ensure_overrides_when_profile_missing() {
  if [ -f "$PROFILE_FILE" ]; then
    return
  fi

  local missing=()
  if [ -z "$HOST_NAME" ]; then
    missing+=("--host-name")
  fi
  if [ -z "$USER_NAME" ]; then
    missing+=("--user-name")
  fi
  if [ -z "$REMOTE_PROJECT_DIR" ]; then
    missing+=("--remote-project-dir")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  echo "connection profile was not found:" >&2
  echo "  $PROFILE_FILE" >&2
  echo >&2
  echo "when the profile is missing, pass one-run overrides:" >&2
  echo "  --host-name your.vps.host --user-name root --remote-project-dir /srv/project" >&2
  echo >&2
  echo "missing required override(s): ${missing[*]}" >&2
  exit 1
}

resolve_profile_file() {
  local script_dir script_profile cwd_profile

  if [ "$PROFILE_FILE_SET" = "1" ]; then
    return
  fi

  if [ -f "$PROFILE_FILE" ]; then
    return
  fi

  script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)"
  script_profile="$script_dir/connection.env"
  cwd_profile="$(pwd)/connection.env"

  if [ -f "$script_profile" ]; then
    PROFILE_FILE="$script_profile"
    return
  fi

  if [ -f "$cwd_profile" ]; then
    PROFILE_FILE="$cwd_profile"
  fi
}

write_profile_file() {
  local profile_di
  profile_dir="$(dirname "$PROFILE_FILE")"
  mkdir -p "$profile_dir"
  chmod 700 "$profile_dir" 2>/dev/null || true

  {
    printf '# sticky-codex connection profile\n'
    printf 'HOST_ALIAS="%s"\n' "$HOST_ALIAS"
    printf 'HOST_NAME="%s"\n' "$HOST_NAME"
    printf 'USER_NAME="%s"\n' "$USER_NAME"
    printf 'PORT="%s"\n' "$PORT"
    printf 'IDENTITY_FILE="%s"\n' "$IDENTITY_FILE"
    printf 'REMOTE_PROJECT_DIR="%s"\n' "$REMOTE_PROJECT_DIR"
    printf 'SESSION_NAME="%s"\n' "$SESSION_NAME"
    printf 'IDLE_DAYS="%s"\n' "$IDLE_DAYS"
    printf 'RECONNECT_DELAY_SECONDS="%s"\n' "$RECONNECT_DELAY_SECONDS"
    printf 'SYNC_AUTH="%s"\n' "$SYNC_AUTH"
    printf 'REMOTE_SCRIPT="%s"\n' "$REMOTE_SCRIPT"
    printf 'AUTH_MODE="%s"\n' "$AUTH_MODE"
    printf 'PASSWORD_B64="%s"\n' "$(encode_base64 "$PASSWORD")"
    printf 'PROXY_TYPE="%s"\n' "$PROXY_TYPE"
    printf 'PROXY_SPEC="%s"\n' "$PROXY_SPEC"
    printf 'QUIC_SERVER="%s"\n' "$QUIC_SERVER"
    printf 'QUIC_PORT="%s"\n' "$QUIC_PORT"
    printf 'QUIC_PASSWORD_B64="%s"\n' "$(encode_base64 "$QUIC_PASSWORD")"
    printf 'QUIC_SNI="%s"\n' "$QUIC_SNI"
    printf 'QUIC_LOCAL_SOCKS_PORT="%s"\n' "$QUIC_LOCAL_SOCKS_PORT"
    printf 'QUIC_UPSTREAM_TYPE="%s"\n' "$QUIC_UPSTREAM_TYPE"
    printf 'QUIC_UPSTREAM_SPEC="%s"\n' "$QUIC_UPSTREAM_SPEC"
    printf 'PASSWORD=""\n'
  } > "$PROFILE_FILE"

  chmod 600 "$PROFILE_FILE" 2>/dev/null || true
}

initialize_profile_if_missing() {
  local sync_choice proxy_choice

  if [ -f "$PROFILE_FILE" ]; then
    return
  fi

  if [ -n "$HOST_NAME" ] && [ -n "$USER_NAME" ] && [ -n "$REMOTE_PROJECT_DIR" ]; then
    return
  fi

  if [ ! -t 0 ]; then
    echo "connection profile was not found: $PROFILE_FILE" >&2
    echo "run quick-install once to create it, or pass one-run overrides." >&2
    exit 1
  fi

  echo "connection profile not found. creating one now..."

  HOST_ALIAS="$(prompt_with_default "host alias" "${HOST_ALIAS:-myvps}")"
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
  fi

  if [ "$AUTH_MODE" = "password" ] && [ -z "$PASSWORD" ]; then
    read -r -s -p "ssh password (stored in profile): " PASSWORD
    printf '\n'
  fi

  sync_choice="$(prompt_with_default "sync local Codex auth.json before attach? (Y/n)" "Y")"
  case "$(printf '%s' "$sync_choice" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      SYNC_AUTH="0"
      ;;
    *)
      SYNC_AUTH="1"
      ;;
  esac

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
    if [ -n "$QUIC_PASSWORD" ]; then
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
    QUIC_PORT="61313"
    QUIC_PASSWORD=""
    QUIC_SNI=""
    QUIC_LOCAL_SOCKS_PORT="10809"
    QUIC_UPSTREAM_TYPE="no"
    QUIC_UPSTREAM_SPEC=""
  fi

  write_profile_file
  echo "saved connection profile: $PROFILE_FILE"
}

ensure_required_connection_values() {
  local missing=()
  if [ -z "$HOST_NAME" ]; then
    missing+=("--host-name")
  fi
  if [ -z "$USER_NAME" ]; then
    missing+=("--user-name")
  fi
  if [ -z "$REMOTE_PROJECT_DIR" ]; then
    missing+=("--remote-project-dir")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    [ -n "$HOST_ALIAS" ] || HOST_ALIAS="myvps"
    [ -n "$AUTH_MODE" ] || AUTH_MODE="auto"
    AUTH_MODE="$(normalize_auth_mode "$AUTH_MODE")"
    case "$RECONNECT_DELAY_SECONDS" in
      ''|*[!0-9]*)
        RECONNECT_DELAY_SECONDS="1"
        ;;
      *)
        if [ "$RECONNECT_DELAY_SECONDS" -lt 1 ]; then
          RECONNECT_DELAY_SECONDS="1"
        fi
        ;;
    esac
    if [ "$AUTH_MODE" = "password" ] && [ -z "$PASSWORD" ]; then
      echo "auth mode 'password' requires a saved password in the profile (PASSWORD_B64) or --password." >&2
      exit 1
    fi
    [ -n "$PROXY_TYPE" ] || PROXY_TYPE="no"
    case "$PROXY_TYPE" in
      no|socks5|http|quic|wss)
        ;;
      *)
        echo "invalid proxy type: $PROXY_TYPE (expected no|socks5|http|quic|wss)" >&2
        exit 1
        ;;
    esac
    if [ "$PROXY_TYPE" = "quic" ]; then
      echo "proxy type 'quic' is deprecated; using 'wss' stability mode."
      PROXY_TYPE="wss"
    fi
    if { [ "$PROXY_TYPE" = "socks5" ] || [ "$PROXY_TYPE" = "http" ]; } && [ -z "$PROXY_SPEC" ]; then
      echo "proxy is enabled but proxy spec is empty." >&2
      exit 1
    fi
    if [ "$PROXY_TYPE" = "quic" ] || [ "$PROXY_TYPE" = "wss" ]; then
      [ -n "$QUIC_SERVER" ] || QUIC_SERVER="$HOST_NAME"
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
      QUIC_UPSTREAM_TYPE="$(printf '%s' "$QUIC_UPSTREAM_TYPE" | tr '[:upper:]' '[:lower:]')"
      if [ -z "$QUIC_PASSWORD" ]; then
        echo "proxy type '$PROXY_TYPE' requires QUIC_PASSWORD_B64 (or --quic-password)." >&2
        exit 1
      fi
      case "$QUIC_PORT" in
        ''|*[!0-9]*)
          echo "proxy type '$PROXY_TYPE' requires numeric QUIC_PORT (1-65535)." >&2
          exit 1
          ;;
      esac
      if [ "$QUIC_PORT" -lt 1 ] || [ "$QUIC_PORT" -gt 65535 ]; then
        echo "proxy type '$PROXY_TYPE' requires QUIC_PORT in range 1-65535." >&2
        exit 1
      fi
      case "$QUIC_LOCAL_SOCKS_PORT" in
        ''|*[!0-9]*)
          echo "proxy type '$PROXY_TYPE' requires numeric QUIC_LOCAL_SOCKS_PORT (1-65535)." >&2
          exit 1
          ;;
      esac
      if [ "$QUIC_LOCAL_SOCKS_PORT" -lt 1 ] || [ "$QUIC_LOCAL_SOCKS_PORT" -gt 65535 ]; then
        echo "proxy type '$PROXY_TYPE' requires QUIC_LOCAL_SOCKS_PORT in range 1-65535." >&2
        exit 1
      fi
      case "$QUIC_UPSTREAM_TYPE" in
        no|socks5|http)
          ;;
        *)
          echo "proxy type '$PROXY_TYPE' has invalid QUIC_UPSTREAM_TYPE: $QUIC_UPSTREAM_TYPE (expected no|socks5|http)." >&2
          exit 1
          ;;
      esac
      if { [ "$QUIC_UPSTREAM_TYPE" = "socks5" ] || [ "$QUIC_UPSTREAM_TYPE" = "http" ]; } && [ -z "$QUIC_UPSTREAM_SPEC" ]; then
        echo "proxy type '$PROXY_TYPE' with upstream mode '$QUIC_UPSTREAM_TYPE' requires QUIC_UPSTREAM_SPEC." >&2
        exit 1
      fi
    fi
    return
  fi

  echo "missing required remote connection value(s): ${missing[*]}" >&2
  echo "run quick-install again to populate $PROFILE_FILE, or pass one-run overrides." >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host-alias)
      HOST_ALIAS="${2:-}"
      HOST_ALIAS_SET="1"
      shift 2
      ;;
    --host-name)
      HOST_NAME="${2:-}"
      HOST_NAME_SET="1"
      shift 2
      ;;
    --user-name)
      USER_NAME="${2:-}"
      USER_NAME_SET="1"
      shift 2
      ;;
    --port)
      PORT="${2:-22}"
      PORT_SET="1"
      shift 2
      ;;
    --identity-file)
      IDENTITY_FILE="${2:-}"
      IDENTITY_FILE_SET="1"
      shift 2
      ;;
    --remote-project-dir)
      REMOTE_PROJECT_DIR="${2:-}"
      REMOTE_PROJECT_DIR_SET="1"
      shift 2
      ;;
    --session-name)
      SESSION_NAME="${2:-}"
      SESSION_NAME_SET="1"
      shift 2
      ;;
    --idle-days)
      IDLE_DAYS="${2:-7}"
      IDLE_DAYS_SET="1"
      shift 2
      ;;
    --reconnect-delay-seconds)
      RECONNECT_DELAY_SECONDS="${2:-1}"
      RECONNECT_DELAY_SECONDS_SET="1"
      shift 2
      ;;
    --auth-mode)
      AUTH_MODE="${2:-auto}"
      AUTH_MODE_SET="1"
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      PASSWORD_SET="1"
      shift 2
      ;;
    --proxy-type)
      PROXY_TYPE="${2:-no}"
      PROXY_TYPE_SET="1"
      shift 2
      ;;
    --proxy-spec)
      PROXY_SPEC="${2:-}"
      PROXY_SPEC_SET="1"
      shift 2
      ;;
    --quic-server)
      QUIC_SERVER="${2:-}"
      QUIC_SERVER_SET="1"
      shift 2
      ;;
    --quic-port)
      QUIC_PORT="${2:-61313}"
      QUIC_PORT_SET="1"
      shift 2
      ;;
    --quic-password)
      QUIC_PASSWORD="${2:-}"
      QUIC_PASSWORD_SET="1"
      shift 2
      ;;
    --quic-sni)
      QUIC_SNI="${2:-}"
      QUIC_SNI_SET="1"
      shift 2
      ;;
    --quic-local-socks-port)
      QUIC_LOCAL_SOCKS_PORT="${2:-10809}"
      QUIC_LOCAL_SOCKS_PORT_SET="1"
      shift 2
      ;;
    --quic-upstream-type)
      QUIC_UPSTREAM_TYPE="${2:-no}"
      QUIC_UPSTREAM_TYPE_SET="1"
      shift 2
      ;;
    --quic-upstream-spec)
      QUIC_UPSTREAM_SPEC="${2:-}"
      QUIC_UPSTREAM_SPEC_SET="1"
      shift 2
      ;;
    --profile-file)
      PROFILE_FILE="${2:-}"
      PROFILE_FILE_SET="1"
      shift 2
      ;;
    --no-sync-auth)
      SYNC_AUTH="0"
      SYNC_AUTH_SET="1"
      shift
      ;;
    --remote-script)
      REMOTE_SCRIPT="${2:-}"
      REMOTE_SCRIPT_SET="1"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

resolve_profile_file
initialize_profile_if_missing
ensure_overrides_when_profile_missing
load_profile_if_present
ensure_required_connection_values

if [ -z "$HOST_NAME" ] || [ -z "$USER_NAME" ] || [ -z "$REMOTE_PROJECT_DIR" ]; then
  usage >&2
  exit 1
fi

show_banner() {
  printf '%s\n' "Sticky Codex"
  printf '%s\n' "AGPL-3.0-or-later"
  printf '%s\n' "Morrow Shore https://morrowshore.com"
  printf '\n'
}

get_sanitized_session_name() {
  local remote_path leaf safe

  remote_path="$1"
  leaf="$(basename "$remote_path")"
  if [ -z "$leaf" ] || [ "$leaf" = "/" ] || [ "$leaf" = "." ]; then
    leaf="project"
  fi

  safe="$(printf '%s' "$leaf" | sed 's/[^A-Za-z0-9._-]/-/g' | sed 's/^-*//' | sed 's/-*$//')"
  if [ -z "$safe" ]; then
    safe="project"
  fi

  printf 'codex-%s\n' "$safe"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

install_with_manager() {
  local package_name="$1"

  if has_command apt-get; then
    sudo apt-get update
    sudo apt-get install -y "$package_name"
    return
  fi

  if has_command dnf; then
    sudo dnf install -y "$package_name"
    return
  fi

  if has_command yum; then
    sudo yum install -y "$package_name"
    return
  fi

  if has_command pacman; then
    sudo pacman -Sy --noconfirm "$package_name"
    return
  fi

  if has_command zypper; then
    sudo zypper --non-interactive install "$package_name"
    return
  fi

  if has_command apk; then
    sudo apk add "$package_name"
    return
  fi

  echo "could not find a supported package manager to install $package_name." >&2
  exit 1
}

ensure_ssh_tools() {
  if has_command ssh && has_command scp; then
    return
  fi

  echo "ssh or scp is missing. attempting to install openssh client..."
  if ! has_command sudo; then
    echo "sudo is required to install openssh client automatically." >&2
    exit 1
  fi

  if has_command apt-get; then
    install_with_manager openssh-client
  elif has_command dnf || has_command yum; then
    install_with_manager openssh-clients
  elif has_command apk; then
    install_with_manager openssh
  else
    install_with_manager openssh
  fi

  if ! has_command ssh || ! has_command scp; then
    echo "openssh client installation did not make ssh and scp available." >&2
    exit 1
  fi
}

ensure_sshpass_if_configured() {
  if [ "$AUTH_MODE" != "password" ] || [ -z "$PASSWORD" ]; then
    return
  fi

  if has_command sshpass; then
    return
  fi

  echo "ssh password was provided, but sshpass is not installed. attempting to install sshpass for quick reconnects..."

  if ! has_command sudo; then
    echo "could not auto-install sshpass without sudo. password will be prompted after disconnects." >&2
    return
  fi

  if has_command apt-get; then
    sudo apt-get update || true
    sudo apt-get install -y sshpass || true
  elif has_command dnf; then
    sudo dnf install -y sshpass || true
  elif has_command yum; then
    sudo yum install -y sshpass || true
  elif has_command pacman; then
    sudo pacman -Sy --noconfirm sshpass || true
  elif has_command zypper; then
    sudo zypper --non-interactive install sshpass || true
  elif has_command apk; then
    sudo apk add sshpass || true
  else
    echo "could not find a supported package manager for sshpass. password will be prompted after disconnects." >&2
  fi

  if ! has_command sshpass; then
    echo "could not install sshpass. password will be prompted after disconnects." >&2
  fi
}

ensure_ncat_if_proxy_configured() {
  if [ "$PROXY_TYPE" = "no" ] || [ -z "$PROXY_SPEC" ]; then
    return
  fi

  if has_command ncat; then
    return
  fi

  echo "proxy mode requires ncat. attempting to install ncat..."
  if ! has_command sudo; then
    echo "sudo is required to install ncat automatically." >&2
    exit 1
  fi

  if has_command apt-get; then
    sudo apt-get update || true
    sudo apt-get install -y ncat || sudo apt-get install -y nmap-ncat || true
  elif has_command dnf; then
    sudo dnf install -y nmap-ncat || sudo dnf install -y ncat || true
  elif has_command yum; then
    sudo yum install -y nmap-ncat || sudo yum install -y ncat || true
  elif has_command pacman; then
    sudo pacman -Sy --noconfirm nmap || true
  elif has_command zypper; then
    sudo zypper --non-interactive install ncat || sudo zypper --non-interactive install nmap || true
  elif has_command apk; then
    sudo apk add nmap-ncat || sudo apk add nmap || true
  else
    echo "could not find a supported package manager for ncat." >&2
  fi

  if ! has_command ncat; then
    echo "proxy mode requires ncat in PATH." >&2
    exit 1
  fi
}

install_codex_cli_local() {
  local attempts attempt delay

  if ! has_command npm; then
    echo "npm is missing. attempting to install nodejs and npm..." >&2
    if ! has_command sudo; then
      echo "sudo is required to install nodejs/npm automatically." >&2
      return 1
    fi

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
    else
      echo "could not find a supported package manager for nodejs/npm." >&2
      return 1
    fi
  fi

  if ! has_command npm; then
    echo "npm is still unavailable after attempted install." >&2
    return 1
  fi

  attempts=5
  for attempt in $(seq 1 "$attempts"); do
    if npm install -g @openai/codex; then
      break
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      delay=$(( attempt * 5 ))
      if [ "$delay" -gt 30 ]; then
        delay=30
      fi
      echo "codex npm install failed (attempt $attempt/$attempts). retrying in $delay seconds..." >&2
      sleep "$delay"
    fi
  done

  if ! has_command codex; then
    return 1
  fi

  return 0
}

download_file_with_retry() {
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

resolve_sing_box_bin() {
  if has_command sing-box; then
    QUIC_SINGBOX_BIN="$(command -v sing-box)"
    return 0
  fi

  if [ -x "$HOME/.local/bin/sing-box" ]; then
    QUIC_SINGBOX_BIN="$HOME/.local/bin/sing-box"
    return 0
  fi

  return 1
}

install_sing_box_client() {
  local arch api_url asset_url temp_dir archive_path extracted_bin

  if resolve_sing_box_bin; then
    return 0
  fi

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      arch="amd64"
      ;;
    aarch64|arm64)
      arch="arm64"
      ;;
    *)
      echo "unsupported architecture for automatic sing-box install: $arch" >&2
      return 1
      ;;
  esac

  api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  asset_url="$(curl -fsSL "$api_url" | grep '"browser_download_url"' | cut -d '"' -f 4 | grep "linux-$arch.tar.gz" | head -n1 || true)"
  if [ -z "$asset_url" ]; then
    echo "could not find sing-box release asset for linux-$arch." >&2
    return 1
  fi

  temp_dir="$(mktemp -d)"
  archive_path="$temp_dir/sing-box.tar.gz"
  if ! download_file_with_retry "$asset_url" "$archive_path"; then
    rm -rf "$temp_dir"
    return 1
  fi

  if ! tar -xzf "$archive_path" -C "$temp_dir"; then
    rm -rf "$temp_dir"
    return 1
  fi

  extracted_bin="$(find "$temp_dir" -type f -name "sing-box" | head -n1 || true)"
  if [ -z "$extracted_bin" ]; then
    rm -rf "$temp_dir"
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  install -m 755 "$extracted_bin" "$HOME/.local/bin/sing-box"
  rm -rf "$temp_dir"

  QUIC_SINGBOX_BIN="$HOME/.local/bin/sing-box"
  return 0
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

tcp_port_open() {
  local host="$1"
  local port="$2"
  if has_command timeout; then
    timeout 1 bash -lc "echo > /dev/tcp/$host/$port" >/dev/null 2>&1
    return $?
  fi
  bash -lc "echo > /dev/tcp/$host/$port" >/dev/null 2>&1
}

find_available_local_socks_port() {
  local preferred="$1"
  local search_window=200
  local candidate

  case "$preferred" in
    ''|*[!0-9]*)
      preferred=10809
      ;;
  esac
  if [ "$preferred" -lt 1 ] || [ "$preferred" -gt 65535 ]; then
    preferred=10809
  fi

  if ! tcp_port_open "127.0.0.1" "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi

  candidate=$(( preferred + 1 ))
  while [ "$candidate" -le 65535 ] && [ "$candidate" -le $(( preferred + search_window )) ]; do
    if ! tcp_port_open "127.0.0.1" "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$(( candidate + 1 ))
  done

  return 1
}

start_quic_local_proxy_if_configured() {
  local quic_config_path escaped_server escaped_password escaped_sni
  local upstream_outbound upstream_detour upstream_type
  local escaped_upstream_host escaped_upstream_user escaped_upstream_pass

  if [ "$PROXY_TYPE" != "quic" ]; then
    return
  fi

  [ -n "$QUIC_SERVER" ] || QUIC_SERVER="$HOST_NAME"
  [ -n "$QUIC_PORT" ] || QUIC_PORT="61313"
  [ -n "$QUIC_LOCAL_SOCKS_PORT" ] || QUIC_LOCAL_SOCKS_PORT="10809"
  [ -n "$QUIC_SNI" ] || QUIC_SNI="$QUIC_SERVER"
  [ -n "$QUIC_UPSTREAM_TYPE" ] || QUIC_UPSTREAM_TYPE="no"

  if [ -z "$QUIC_PASSWORD" ]; then
    echo "quic proxy mode requires QUIC_PASSWORD." >&2
    exit 1
  fi

  if ! resolve_sing_box_bin && [ -t 0 ]; then
    local install_quic_core_choice
    install_quic_core_choice="$(prompt_with_default "quic core (sing-box) is missing on this client. install now? (Y/n)" "Y")"
    case "$(printf '%s' "$install_quic_core_choice" | tr '[:upper:]' '[:lower:]')" in
      n|no)
        echo "quic mode needs sing-box on the client. install was skipped by user." >&2
        exit 1
        ;;
    esac
  fi

  if ! install_sing_box_client; then
    echo "failed to install sing-box client automatically for quic proxy mode." >&2
    exit 1
  fi

  if tcp_port_open "127.0.0.1" "$QUIC_LOCAL_SOCKS_PORT"; then
    local next_port
    next_port="$(find_available_local_socks_port "$QUIC_LOCAL_SOCKS_PORT" || true)"
    if [ -z "$next_port" ]; then
      echo "local port $QUIC_LOCAL_SOCKS_PORT is already in use and no free nearby port was found for quic tunnel." >&2
      exit 1
    fi
    echo "local port $QUIC_LOCAL_SOCKS_PORT is already in use; quic tunnel will use $next_port."
    QUIC_LOCAL_SOCKS_PORT="$next_port"
  fi

  QUIC_TMP_DIR="$(mktemp -d)"
  quic_config_path="$QUIC_TMP_DIR/sing-box-quic-client.json"
  escaped_server="$(json_escape "$QUIC_SERVER")"
  escaped_password="$(json_escape "$QUIC_PASSWORD")"
  escaped_sni="$(json_escape "$QUIC_SNI")"
  upstream_outbound=""
  upstream_detour=""

  case "$QUIC_UPSTREAM_TYPE" in
    no)
      ;;
    socks5|http)
      if [ -z "$QUIC_UPSTREAM_SPEC" ]; then
        echo "quic upstream proxy mode '$QUIC_UPSTREAM_TYPE' requires QUIC_UPSTREAM_SPEC." >&2
        exit 1
      fi
      parse_proxy_spec "$QUIC_UPSTREAM_SPEC"
      escaped_upstream_host="$(json_escape "$PROXY_HOST")"
      escaped_upstream_user="$(json_escape "$PROXY_USER")"
      escaped_upstream_pass="$(json_escape "$PROXY_PASS")"
      if [ "$QUIC_UPSTREAM_TYPE" = "socks5" ]; then
        upstream_type="socks"
      else
        upstream_type="http"
      fi
      if [ -n "$PROXY_USER" ]; then
        upstream_outbound=",
    {
      \"type\": \"$upstream_type\",
      \"tag\": \"quic-upstream\",
      \"server\": \"$escaped_upstream_host\",
      \"server_port\": $PROXY_PORT,
      \"username\": \"$escaped_upstream_user\",
      \"password\": \"$escaped_upstream_pass\"
    }"
      else
        upstream_outbound=",
    {
      \"type\": \"$upstream_type\",
      \"tag\": \"quic-upstream\",
      \"server\": \"$escaped_upstream_host\",
      \"server_port\": $PROXY_PORT
    }"
      fi
      upstream_detour=", \"detour\": \"quic-upstream\""
      ;;
    *)
      echo "invalid quic upstream type: $QUIC_UPSTREAM_TYPE (expected no|socks5|http)." >&2
      exit 1
      ;;
  esac

  cat > "$quic_config_path" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": $QUIC_LOCAL_SOCKS_PORT
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": "$escaped_server",
      "server_port": $QUIC_PORT,
      "password": "$escaped_password",
      "tls": {
        "enabled": true,
        "server_name": "$escaped_sni",
        "insecure": true
      }$upstream_detour
    }
    $upstream_outbound
  ],
  "route": { "final": "hy2-out" }
}
EOF

  "$QUIC_SINGBOX_BIN" run -c "$quic_config_path" >/dev/null 2>&1 &
  QUIC_PID="$!"

  for _ in $(seq 1 20); do
    sleep 0.5
    if tcp_port_open "127.0.0.1" "$QUIC_LOCAL_SOCKS_PORT"; then
      PROXY_TYPE="socks5"
      PROXY_SPEC="127.0.0.1:$QUIC_LOCAL_SOCKS_PORT"
      return
    fi
    if ! kill -0 "$QUIC_PID" >/dev/null 2>&1; then
      break
    fi
  done

  echo "failed to start local quic tunnel client (sing-box)." >&2
  exit 1
}

start_wss_local_proxy_if_configured() {
  local wss_config_path escaped_server escaped_password escaped_sni
  local upstream_outbound upstream_detour upstream_type
  local escaped_upstream_host escaped_upstream_user escaped_upstream_pass

  if [ "$PROXY_TYPE" != "wss" ]; then
    return
  fi

  [ -n "$QUIC_SERVER" ] || QUIC_SERVER="$HOST_NAME"
  [ -n "$QUIC_PORT" ] || QUIC_PORT="13131"
  [ -n "$QUIC_LOCAL_SOCKS_PORT" ] || QUIC_LOCAL_SOCKS_PORT="10809"
  [ -n "$QUIC_SNI" ] || QUIC_SNI="$QUIC_SERVER"
  [ -n "$QUIC_UPSTREAM_TYPE" ] || QUIC_UPSTREAM_TYPE="no"

  if [ -z "$QUIC_PASSWORD" ]; then
    echo "wss proxy mode requires QUIC_PASSWORD." >&2
    exit 1
  fi

  if ! resolve_sing_box_bin && [ -t 0 ]; then
    local install_wss_core_choice
    install_wss_core_choice="$(prompt_with_default "wss core (sing-box) is missing on this client. install now? (Y/n)" "Y")"
    case "$(printf '%s' "$install_wss_core_choice" | tr '[:upper:]' '[:lower:]')" in
      n|no)
        echo "wss mode needs sing-box on the client. install was skipped by user." >&2
        exit 1
        ;;
    esac
  fi

  if ! install_sing_box_client; then
    echo "failed to install sing-box client automatically for wss proxy mode." >&2
    exit 1
  fi

  if tcp_port_open "127.0.0.1" "$QUIC_LOCAL_SOCKS_PORT"; then
    local next_port
    next_port="$(find_available_local_socks_port "$QUIC_LOCAL_SOCKS_PORT" || true)"
    if [ -z "$next_port" ]; then
      echo "local port $QUIC_LOCAL_SOCKS_PORT is already in use and no free nearby port was found for wss tunnel." >&2
      exit 1
    fi
    echo "local port $QUIC_LOCAL_SOCKS_PORT is already in use; wss tunnel will use $next_port."
    QUIC_LOCAL_SOCKS_PORT="$next_port"
  fi

  QUIC_TMP_DIR="$(mktemp -d)"
  wss_config_path="$QUIC_TMP_DIR/sing-box-wss-client.json"
  escaped_server="$(json_escape "$QUIC_SERVER")"
  escaped_password="$(json_escape "$QUIC_PASSWORD")"
  escaped_sni="$(json_escape "$QUIC_SNI")"
  upstream_outbound=""
  upstream_detour=""

  case "$QUIC_UPSTREAM_TYPE" in
    no)
      ;;
    socks5|http)
      if [ -z "$QUIC_UPSTREAM_SPEC" ]; then
        echo "wss upstream proxy mode '$QUIC_UPSTREAM_TYPE' requires QUIC_UPSTREAM_SPEC." >&2
        exit 1
      fi
      parse_proxy_spec "$QUIC_UPSTREAM_SPEC"
      escaped_upstream_host="$(json_escape "$PROXY_HOST")"
      escaped_upstream_user="$(json_escape "$PROXY_USER")"
      escaped_upstream_pass="$(json_escape "$PROXY_PASS")"
      if [ "$QUIC_UPSTREAM_TYPE" = "socks5" ]; then
        upstream_type="socks"
      else
        upstream_type="http"
      fi
      if [ -n "$PROXY_USER" ]; then
        upstream_outbound=",
    {
      \"type\": \"$upstream_type\",
      \"tag\": \"wss-upstream\",
      \"server\": \"$escaped_upstream_host\",
      \"server_port\": $PROXY_PORT,
      \"username\": \"$escaped_upstream_user\",
      \"password\": \"$escaped_upstream_pass\"
    }"
      else
        upstream_outbound=",
    {
      \"type\": \"$upstream_type\",
      \"tag\": \"wss-upstream\",
      \"server\": \"$escaped_upstream_host\",
      \"server_port\": $PROXY_PORT
    }"
      fi
      upstream_detour=", \"detour\": \"wss-upstream\""
      ;;
    *)
      echo "invalid wss upstream type: $QUIC_UPSTREAM_TYPE (expected no|socks5|http)." >&2
      exit 1
      ;;
  esac

  cat > "$wss_config_path" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": $QUIC_LOCAL_SOCKS_PORT
    }
  ],
  "outbounds": [
    {
      "type": "trojan",
      "tag": "wss-out",
      "server": "$escaped_server",
      "server_port": $QUIC_PORT,
      "password": "$escaped_password",
      "tls": {
        "enabled": true,
        "server_name": "$escaped_sni",
        "insecure": true
      },
      "transport": {
        "type": "ws",
        "path": "/sticky-codex"
      }$upstream_detour
    }
    $upstream_outbound
  ],
  "route": { "final": "wss-out" }
}
EOF

  "$QUIC_SINGBOX_BIN" run -c "$wss_config_path" >/dev/null 2>&1 &
  QUIC_PID="$!"

  for _ in $(seq 1 20); do
    sleep 0.5
    if tcp_port_open "127.0.0.1" "$QUIC_LOCAL_SOCKS_PORT"; then
      PROXY_TYPE="socks5"
      PROXY_SPEC="127.0.0.1:$QUIC_LOCAL_SOCKS_PORT"
      return
    fi
    if ! kill -0 "$QUIC_PID" >/dev/null 2>&1; then
      break
    fi
  done

  echo "failed to start local wss tunnel client (sing-box)." >&2
  exit 1
}
ensure_codex() {
  if has_command codex; then
    return
  fi

  if [ -t 0 ]; then
    local install_choice
    install_choice="$(prompt_with_default "codex cli is missing on this client. install now? (Y/n)" "Y")"
    case "$(printf '%s' "$install_choice" | tr '[:upper:]' '[:lower:]')" in
      n|no)
        echo "codex install skipped by user." >&2
        ;;
      *)
        if install_codex_cli_local && has_command codex; then
          return
        fi
        echo "automatic codex install on this client failed." >&2
        ;;
    esac
  fi

  echo "codex cli is not installed or not in PATH on this machine." >&2
  exit 1
}

get_local_codex_auth_path() {
  if [ -n "${CODEX_HOME:-}" ] && [ -f "${CODEX_HOME}/auth.json" ]; then
    printf '%s\n' "${CODEX_HOME}/auth.json"
    return
  fi

  printf '%s\n' "$HOME/.codex/auth.json"
}

run_ssh() {
  if [ "$AUTH_MODE" = "password" ] && [ -n "$PASSWORD" ] && has_command sshpass; then
    SSHPASS="$PASSWORD" sshpass -e ssh "$@"
    return
  fi

  ssh "$@"
}

run_scp() {
  if [ "$AUTH_MODE" = "password" ] && [ -n "$PASSWORD" ] && has_command sshpass; then
    SSHPASS="$PASSWORD" sshpass -e scp "$@"
    return
  fi

  scp "$@"
}

install_remote_codex_cli() {
  local install_cmd
  install_cmd="$(cat <<'EOF'
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
EOF
)"

  run_ssh -tt -F "$SSH_CONFIG_PATH" "$HOST_ALIAS" "bash -lc $(quote_for_bash_single "$install_cmd")"
}

sync_local_codex_auth_to_remote() {
  local local_auth
  local_auth="$(get_local_codex_auth_path)"

  if [ ! -f "$local_auth" ]; then
    cat >&2 <<EOF
local Codex auth.json was not found at:
  $local_auth

do this first:
  1. ensure ~/.codex/config.toml contains:
       cli_auth_credentials_store = "file"
  2. run:
       codex login
EOF
    exit 1
  fi

  echo "syncing local Codex auth to VPS..."
  run_ssh -F "$SSH_CONFIG_PATH" "$HOST_ALIAS" "mkdir -p ~/.codex && chmod 700 ~/.codex"
  run_scp -F "$SSH_CONFIG_PATH" "$local_auth" "${HOST_ALIAS}:~/.codex/auth.json"
}

quote_for_bash_single() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

write_temp_ssh_config() {
  local proxy_command
  {
    printf 'Host %s\n' "$HOST_ALIAS"
    printf '    HostName %s\n' "$HOST_NAME"
    printf '    User %s\n' "$USER_NAME"
    printf '    Port %s\n' "$PORT"
    printf '    ServerAliveInterval 15\n'
    printf '    ServerAliveCountMax 120\n'
    printf '    TCPKeepAlive yes\n'
    printf '    RequestTTY force\n'

    case "$AUTH_MODE" in
      password)
        printf '    PreferredAuthentications password,keyboard-interactive\n'
        printf '    PubkeyAuthentication no\n'
        printf '    IdentitiesOnly no\n'
        ;;
      key)
        if [ -n "$IDENTITY_FILE" ]; then
          printf '    IdentitiesOnly yes\n'
          printf '    IdentityFile %s\n' "$IDENTITY_FILE"
        else
          printf '    IdentitiesOnly no\n'
        fi
        ;;
      auto)
        if [ -n "$IDENTITY_FILE" ]; then
          printf '    IdentityFile %s\n' "$IDENTITY_FILE"
        fi
        ;;
    esac

    if [ "$PROXY_TYPE" != "no" ] && [ -n "$PROXY_SPEC" ]; then
      proxy_command="$(build_proxy_command "%h" "%p")"
      printf '    ProxyCommand %s\n' "$proxy_command"
    fi
  } > "$SSH_CONFIG_PATH"
}

start_reconnect_loop() {
  local project_arg session_arg launch_cmd remote_cmd exit_code delay

  project_arg="$(quote_for_bash_single "$REMOTE_PROJECT_DIR")"
  session_arg="$(quote_for_bash_single "$SESSION_NAME")"
  launch_cmd="$REMOTE_SCRIPT --project-dir $project_arg --session-name $session_arg --idle-days $IDLE_DAYS"
  remote_cmd="bash -lc $(quote_for_bash_single "$launch_cmd")"

  while true; do
    printf '\n'
    printf 'connecting to %s | session=%s | project=%s\n' "$HOST_ALIAS" "$SESSION_NAME" "$REMOTE_PROJECT_DIR"
    if run_ssh -tt -F "$SSH_CONFIG_PATH" "$HOST_ALIAS" "$remote_cmd"; then
      exit_code=0
    else
      exit_code="$?"
    fi
    delay="1"

    if [ "$exit_code" -ne 0 ]; then
      printf 'remote launcher exited with code %s.\n' "$exit_code"
    fi
    if [ "$exit_code" -eq 255 ]; then
      printf 'ssh transport failed (exit 255). check sshd/firewall/fail2ban/network reachability.\n'
    fi

    printf '\n'
    printf 'disconnected. reconnecting in %s seconds...\n' "$delay"
    sleep "$delay"
  done
}

test_remote_prereqs() {
  local remote_script_arg project_arg check_cmd cmd exit_code install_choice preflight_output output_lower

  remote_script_arg="$(quote_for_bash_single "$REMOTE_SCRIPT")"
  project_arg="$(quote_for_bash_single "$REMOTE_PROJECT_DIR")"
  check_cmd="if [ ! -x $remote_script_arg ]; then echo 'remote script not found or not executable: $REMOTE_SCRIPT' >&2; exit 20; fi; if [ ! -d $project_arg ]; then echo 'remote project directory not found; creating: $REMOTE_PROJECT_DIR' >&2; if ! mkdir -p $project_arg; then echo 'failed to create remote project directory: $REMOTE_PROJECT_DIR' >&2; exit 21; fi; fi"
  check_cmd="$check_cmd; if ! command -v codex >/dev/null 2>&1; then echo 'codex is not installed or not in PATH on the remote host.' >&2; exit 22; fi"
  cmd="bash -lc $(quote_for_bash_single "$check_cmd")"

  preflight_output="$(run_ssh -F "$SSH_CONFIG_PATH" "$HOST_ALIAS" "$cmd" 2>&1)"
  exit_code="$?"
  if [ "$exit_code" -eq 0 ]; then
    if [ -n "$preflight_output" ]; then
      echo "remote preflight: $preflight_output"
    fi
    return 0
  fi
  output_lower="$(printf '%s' "$preflight_output" | tr '[:upper:]' '[:lower:]')"

  if { [ "$exit_code" -eq 22 ] || printf '%s' "$output_lower" | grep -q "codex is not installed or not in path on the remote host"; } && [ -t 0 ]; then
    install_choice="$(prompt_with_default "remote codex is missing on $HOST_ALIAS. install now? (Y/n)" "Y")"
    case "$(printf '%s' "$install_choice" | tr '[:upper:]' '[:lower:]')" in
      n|no)
        ;;
      *)
        echo "installing codex on remote host..."
        if install_remote_codex_cli; then
          if run_ssh -F "$SSH_CONFIG_PATH" "$HOST_ALIAS" "command -v codex >/dev/null 2>&1"; then
            echo "remote codex install succeeded."
            return
          fi
        fi
        echo "automatic remote codex install failed." >&2
        ;;
    esac
  fi

  if [ "$exit_code" -eq 255 ] || printf '%s' "$output_lower" | grep -Eq "connection refused|network error|timed out|timeout|name or service not known|could not resolve|no route to host|connection reset|connection closed|unexpectedly closed network connection|remote side unexpectedly closed"; then
    if [ "$PROXY_TYPE" = "wss" ]; then
      echo "wss hint: on the server, run 'sudo systemctl restart sticky-codex-wss.service' and inspect 'journalctl -u sticky-codex-wss.service --no-pager -n 80'." >&2
    fi
    if [ -n "$preflight_output" ]; then
      echo "remote preflight failed due to SSH transport/connectivity issue (exit $exit_code): $preflight_output" >&2
    else
      echo "remote preflight failed due to SSH transport/connectivity issue (exit $exit_code)." >&2
    fi
    return 1
  fi

  if [ "$exit_code" -ge 20 ] && [ "$exit_code" -le 29 ]; then
    echo "remote preflight failed with exit code $exit_code." >&2
    exit 1
  fi

  if [ -n "$preflight_output" ]; then
    echo "remote preflight could not complete (exit $exit_code): $preflight_output" >&2
  else
    echo "remote preflight could not complete (exit $exit_code)." >&2
  fi
  return 1
}

cleanup_local_helpers() {
  if [ -n "${QUIC_PID:-}" ] && kill -0 "$QUIC_PID" >/dev/null 2>&1; then
    kill "$QUIC_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "${QUIC_TMP_DIR:-}" ] && [ -d "$QUIC_TMP_DIR" ]; then
    rm -rf "$QUIC_TMP_DIR"
  fi
  if [ -n "${SSH_CONFIG_PATH:-}" ] && [ -f "$SSH_CONFIG_PATH" ]; then
    rm -f "$SSH_CONFIG_PATH"
  fi
}

if [ -z "$SESSION_NAME" ]; then
  SESSION_NAME="$(get_sanitized_session_name "$REMOTE_PROJECT_DIR")"
fi

AUTH_MODE="$(normalize_auth_mode "$AUTH_MODE")"

show_banner
ensure_ssh_tools
ensure_sshpass_if_configured
ensure_codex

SSH_CONFIG_PATH="$(mktemp)"
trap cleanup_local_helpers EXIT
start_wss_local_proxy_if_configured
start_quic_local_proxy_if_configured
ensure_ncat_if_proxy_configured

write_temp_ssh_config

preflight_ready=1
if ! test_remote_prereqs; then
  preflight_ready=0
fi

if [ "$SYNC_AUTH" = "1" ] && [ "$preflight_ready" = "1" ]; then
  sync_local_codex_auth_to_remote
elif [ "$SYNC_AUTH" = "1" ]; then
  echo "skipping local auth sync until remote connectivity stabilizes."
fi

start_reconnect_loop
