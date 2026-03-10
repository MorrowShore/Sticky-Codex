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
  local target_dir
  target_dir="$(dirname "$TARGET")"

  if [ -d "$target_dir" ] && [ -w "$target_dir" ]; then
    install -m 755 "$TMP_FILE" "$TARGET"
  else
    sudo mkdir -p "$target_dir"
    sudo install -m 755 "$TMP_FILE" "$TARGET"
  fi
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
