#!/usr/bin/env bash
set -euo pipefail

# Restores /etc/nginx from a backup tar.gz created by nginx-backup.sh.
# Usage:
#   sudo bash nginx-restore.sh /path/to/nginx-YYYYmmdd-HHMMSS.tar.gz

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This script needs sudo. Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/nginx-backup.tar.gz" >&2
  exit 2
fi

BK="$1"
if [[ ! -f "$BK" ]]; then
  echo "ERROR: backup file not found: $BK" >&2
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "ERROR: nginx is not installed (can't validate config)." >&2
  exit 1
fi

# Backup current config before overwriting
TS="$(date +%Y%m%d-%H%M%S)"
CURRENT_BK="/root/nginx-before-restore-${TS}.tar.gz"
if [[ -d /etc/nginx ]]; then
  tar -czf "$CURRENT_BK" -C /etc nginx
  echo "Backup of current nginx saved to: $CURRENT_BK"
fi

# Restore
rm -rf /etc/nginx
mkdir -p /etc

tar -xzf "$BK" -C /etc

# Validate + reload
nginx -t
systemctl reload nginx

echo "OK: nginx restored and reloaded."
