#!/usr/bin/env bash
set -euo pipefail

# Jmaka server helper (menu launcher)
# Provides a simple menu for:
# 1) Install/Update Jmaka
# 2) Reset/Uninstall Jmaka (removes instances + nginx includes/snippets)
# 3) Backup/Restore nginx config

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die_missing() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "ERROR: required file not found: $f" >&2
    echo "Re-download scripts or run from the same directory." >&2
    exit 1
  fi
}

run_install() {
  die_missing "${SCRIPT_DIR}/install.sh"
  bash "${SCRIPT_DIR}/install.sh" --interactive
}

run_reset() {
  die_missing "${SCRIPT_DIR}/jmaka-reset.sh"
  bash "${SCRIPT_DIR}/jmaka-reset.sh"
}

run_nginx_backup() {
  die_missing "${SCRIPT_DIR}/nginx-backup.sh"
  bash "${SCRIPT_DIR}/nginx-backup.sh"
}

run_nginx_restore() {
  die_missing "${SCRIPT_DIR}/nginx-restore.sh"
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
