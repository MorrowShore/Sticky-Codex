#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=""
SESSION_NAME=""
IDLE_DAYS="7"
CODEX_CMD="${CODEX_CMD:-codex}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

usage() {
  cat <<'EOF'
usage:
  codex-vps.sh --project-dir /remote/path --session-name mysession [--idle-days 7]

behavior:
- keeps codex running inside tmux
- reattaches if the session already exists
- respawns codex with "codex resume --last || codex" if the pane is no longer running codex
- kills the tmux session if the last reconnect heartbeat is older than n days

install example:
  sudo install -m 755 ./codex-vps.sh /usr/local/bin/codex-vps
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --session-name)
      SESSION_NAME="${2:-}"
      shift 2
      ;;
    --idle-days)
      IDLE_DAYS="${2:-7}"
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

if [ -z "$PROJECT_DIR" ] || [ -z "$SESSION_NAME" ]; then
  usage >&2
  exit 1
fi

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

ensure_tmux() {
  if has_command tmux; then
    return
  fi

  echo "tmux is not installed. attempting to install it..."
  if ! has_command sudo; then
    echo "sudo is required to install tmux automatically." >&2
    exit 1
  fi

  install_with_manager tmux

  if ! has_command tmux; then
    echo "tmux installation did not succeed." >&2
    exit 1
  fi
}

ensure_codex() {
  if has_command "$CODEX_CMD"; then
    return
  fi

  cat >&2 <<EOF
codex cli is not installed or not in path.
install codex on the remote machine, then rerun this command.
EOF
  exit 1
}

if [ ! -d "$PROJECT_DIR" ]; then
  echo "project directory does not exist: $PROJECT_DIR" >&2
  exit 1
fi

ensure_tmux
ensure_codex

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/codex-remote"
SAFE_SESSION="$(printf '%s' "$SESSION_NAME" | tr -cs 'A-Za-z0-9._-' '_')"
STATE_DIR="$STATE_ROOT/$SAFE_SESSION"
LAST_SEEN_FILE="$STATE_DIR/last_seen"
PROJECT_FILE="$STATE_DIR/project_dir"

mkdir -p "$STATE_DIR" "$CODEX_HOME"
chmod 700 "$CODEX_HOME" || true

now_epoch() {
  date +%s
}

session_exists() {
  tmux has-session -t "$SESSION_NAME" 2>/dev/null
}

write_heartbeat() {
  now_epoch > "$LAST_SEEN_FILE"
  printf '%s\n' "$PROJECT_DIR" > "$PROJECT_FILE"
}

kill_if_idle_expired() {
  if [ ! -f "$LAST_SEEN_FILE" ]; then
    return
  fi

  local last_seen now max_age
  last_seen="$(cat "$LAST_SEEN_FILE" 2>/dev/null || echo 0)"
  now="$(now_epoch)"
  max_age="$(( IDLE_DAYS * 24 * 60 * 60 ))"

  if [ "$last_seen" -gt 0 ] && [ $(( now - last_seen )) -ge "$max_age" ]; then
    if session_exists; then
      tmux kill-session -t "$SESSION_NAME" || true
    fi
    rm -f "$LAST_SEEN_FILE"
  fi
}

build_launch_cmd() {
  cat <<EOF
export CODEX_HOME=$(printf '%q' "$CODEX_HOME")
cd $(printf '%q' "$PROJECT_DIR")
if [ -f $(printf '%q' "$CODEX_HOME/auth.json") ]; then
  $CODEX_CMD resume --last || $CODEX_CMD
  code=\$?
  echo
  echo "codex exited with code \$code. leaving shell open for troubleshooting."
  echo "restart manually with: $CODEX_CMD resume --last || $CODEX_CMD"
  echo
  exec bash -li
else
  echo
  echo "no codex auth found at $CODEX_HOME/auth.json"
  echo "sync auth from a client launcher or run: codex login --device-auth"
  echo
  exec bash -li
fi
EOF
}

start_session() {
  local launch_cmd
  launch_cmd="$(build_launch_cmd)"
  tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" "bash -lc $(printf '%q' "$launch_cmd")"
}

pane_running_codex() {
  local current
  current="$(tmux display-message -p -t "$SESSION_NAME:0.0" '#{pane_current_command}' 2>/dev/null || true)"
  [ "$current" = "codex" ]
}

ensure_session_matches_project() {
  if [ ! -f "$PROJECT_FILE" ]; then
    return
  fi

  local prior_project
  prior_project="$(cat "$PROJECT_FILE" 2>/dev/null || true)"
  if [ -n "$prior_project" ] && [ "$prior_project" != "$PROJECT_DIR" ] && session_exists; then
    tmux kill-session -t "$SESSION_NAME" || true
  fi
}

ensure_session() {
  kill_if_idle_expired
  ensure_session_matches_project

  if ! session_exists; then
    start_session
    return
  fi

  if ! pane_running_codex; then
    local launch_cmd
    launch_cmd="$(build_launch_cmd)"
    tmux respawn-pane -k -t "$SESSION_NAME:0.0" "bash -lc $(printf '%q' "$launch_cmd")"
  fi
}

main() {
  write_heartbeat
  ensure_session
  exec tmux attach-session -t "$SESSION_NAME"
}

main
