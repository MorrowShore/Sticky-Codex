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
RECONNECT_DELAY_SECONDS="3"
SYNC_AUTH="1"
REMOTE_SCRIPT="/usr/local/bin/codex-vps"
AUTH_MODE="auto"
PASSWORD=""
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
PROFILE_FILE_SET="0"

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
  --reconnect-delay-seconds 3
  --auth-mode auto|key|password
  --password VALUE
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
      RECONNECT_DELAY_SECONDS="${2:-3}"
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

ensure_overrides_when_profile_missing
load_profile_if_present
ensure_required_connection_values

if [ -z "$HOST_NAME" ] || [ -z "$USER_NAME" ] || [ -z "$REMOTE_PROJECT_DIR" ]; then
  usage >&2
  exit 1
fi

show_banner() {
  printf '%s\n' "sticky-codex"
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

ensure_codex() {
  if has_command codex; then
    return
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
  {
    printf 'Host %s\n' "$HOST_ALIAS"
    printf '    HostName %s\n' "$HOST_NAME"
    printf '    User %s\n' "$USER_NAME"
    printf '    Port %s\n' "$PORT"
    printf '    ServerAliveInterval 30\n'
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
  } > "$SSH_CONFIG_PATH"
}

start_reconnect_loop() {
  local project_arg session_arg launch_cmd remote_cmd

  project_arg="$(quote_for_bash_single "$REMOTE_PROJECT_DIR")"
  session_arg="$(quote_for_bash_single "$SESSION_NAME")"
  launch_cmd="$REMOTE_SCRIPT --project-dir $project_arg --session-name $session_arg --idle-days $IDLE_DAYS"
  remote_cmd="bash -lc $(quote_for_bash_single "$launch_cmd")"

  while true; do
    printf '\n'
    printf 'connecting to %s | session=%s | project=%s\n' "$HOST_ALIAS" "$SESSION_NAME" "$REMOTE_PROJECT_DIR"
    run_ssh -tt -F "$SSH_CONFIG_PATH" "$HOST_ALIAS" "$remote_cmd"

    printf '\n'
    printf 'disconnected. reconnecting in %s seconds...\n' "$RECONNECT_DELAY_SECONDS"
    sleep "$RECONNECT_DELAY_SECONDS"
  done
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
trap 'rm -f "$SSH_CONFIG_PATH"' EXIT

write_temp_ssh_config

if [ "$SYNC_AUTH" = "1" ]; then
  sync_local_codex_auth_to_remote
fi

start_reconnect_loop
