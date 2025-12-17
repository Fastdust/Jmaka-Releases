#!/usr/bin/env bash
set -euo pipefail

# Creates a tar.gz backup of /etc/nginx.
# Output: ~/jmaka-backups/nginx/nginx-YYYYmmdd-HHMMSS.tar.gz (for the ORIGINAL user when using sudo)

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This script needs sudo. Re-running with sudo..."
  exec sudo -E NGINX_BK_ORIG_USER="${USER:-}" NGINX_BK_ORIG_HOME="${HOME:-}" bash "$0" "$@"
fi

ORIG_USER="${NGINX_BK_ORIG_USER:-${SUDO_USER:-root}}"
ORIG_HOME="${NGINX_BK_ORIG_HOME:-""}"
if [[ -z "$ORIG_HOME" && -n "$ORIG_USER" ]]; then
  ORIG_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6 || true)"
fi
ORIG_HOME="${ORIG_HOME:-/root}"

BACKUP_DIR="${ORIG_HOME}/jmaka-backups/nginx"
mkdir -p "$BACKUP_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR}/nginx-${TS}.tar.gz"

if [[ ! -d /etc/nginx ]]; then
  echo "ERROR: /etc/nginx not found" >&2
  exit 1
fi

tar -czf "$OUT" -C /etc nginx

echo "OK: nginx backup created: $OUT"
