#!/usr/bin/env bash
set -euo pipefail

# Jmaka server helper (menu launcher)
# Provides a simple menu for:
# 1) Install/Update Jmaka
# 2) Reset/Uninstall Jmaka (removes instances + nginx includes/snippets)
# 3) Backup/Restore nginx config

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_BASE="https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main"

ensure_file() {
  local name="$1"
  local dest="${SCRIPT_DIR}/${name}"

  if [[ -f "$dest" ]]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download missing helper scripts." >&2
    exit 1
  fi

  echo "Downloading missing script: ${name}"
  curl -fsSL -o "$dest" "${RAW_BASE}/${name}"
  chmod +x "$dest" || true
}

run_install() {
  ensure_file "install.sh"
  bash "${SCRIPT_DIR}/install.sh" --interactive
}

run_reset() {
  ensure_file "jmaka-reset.sh"
  bash "${SCRIPT_DIR}/jmaka-reset.sh"
}

run_nginx_backup() {
  ensure_file "nginx-backup.sh"
  bash "${SCRIPT_DIR}/nginx-backup.sh"
}

run_nginx_restore() {
  ensure_file "nginx-restore.sh"
  local p=""
  echo "Enter path to nginx backup tar.gz (created by nginx-backup.sh):"
  read -r -p "> " p
  if [[ -z "$p" ]]; then
    echo "Cancelled."
    return 0
  fi
  bash "${SCRIPT_DIR}/nginx-restore.sh" "$p"
}

while true; do
  echo ""
  echo "Jmaka menu"
  echo "  1) Install / Update"
  echo "  2) Reset / Uninstall (removes all instances + nginx includes/snippets)"
  echo "  3) Nginx backup"
  echo "  4) Nginx restore"
  echo "  0) Exit"
  echo ""

  choice=""
  read -r -p "Choose [0-4]: " choice

  case "$choice" in
    1) run_install ;;
    2) run_reset ;;
    3) run_nginx_backup ;;
    4) run_nginx_restore ;;
    0) exit 0 ;;
    *) echo "Unknown choice." ;;
  esac

done
