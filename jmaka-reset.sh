#!/usr/bin/env bash
set -euo pipefail

# Resets a server to the state *before* Jmaka installation:
# - stops/disables/removes jmaka-*.service unit files
# - removes /var/www/jmaka/*
# - removes jmaka snippet files from /etc/nginx/snippets
# - removes injected include lines from nginx vhosts
# - reloads systemd + nginx

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This script needs sudo. Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

CONFIRM=""
echo "WARNING: This will uninstall ALL Jmaka instances and modify nginx configs."
echo "Type DELETE to continue:"
read -r CONFIRM
if [[ "$CONFIRM" != "DELETE" ]]; then
  echo "Cancelled."
  exit 0
fi

# 1) systemd services
if command -v systemctl >/dev/null 2>&1; then
  for f in /etc/systemd/system/jmaka-*.service; do
    [[ -e "$f" ]] || continue
    svc="$(basename "$f" .service)"
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    rm -f "$f"
    rm -f "/etc/systemd/system/multi-user.target.wants/${svc}.service" 2>/dev/null || true
  done
  systemctl daemon-reload || true
fi

# 2) remove app data
if [[ -d /var/www/jmaka ]]; then
  rm -rf /var/www/jmaka/*
fi

# 3) remove injected include lines from vhosts (with backups)
# IMPORTANT: backups must NOT be placed inside sites-enabled/ if your nginx uses `include .../*;`
# (otherwise nginx will start loading the backup file too).
NGINX_BK_DIR="/etc/nginx/jmaka-backups"
mkdir -p "$NGINX_BK_DIR"

remove_include_from_tree() {
  local root="$1"
  [[ -d "$root" ]] || return 0

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue

    if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/snippets/jmaka-.*\.location\.conf;' "$file"; then
      continue
    fi

    ts="$(date +%Y%m%d-%H%M%S)"
    base="$(basename "$file")"
    cp -a "$file" "${NGINX_BK_DIR}/${base}.bak.${ts}"
    sed -i -E '/^[[:space:]]*include[[:space:]]+\/etc\/nginx\/snippets\/jmaka-.*\.location\.conf;/d' "$file"
  done < <(find "$root" -type f -name '*.conf' 2>/dev/null)
}

remove_include_from_tree /etc/nginx/sites-enabled
remove_include_from_tree /etc/nginx/sites-available

# 4) remove nginx snippet files (after removing includes)
rm -f /etc/nginx/snippets/jmaka-*.location.conf 2>/dev/null || true
rm -f /etc/nginx/snippets/jmaka-*.conf 2>/dev/null || true

# 5) validate + reload nginx
if command -v nginx >/dev/null 2>&1; then
  nginx -t
  systemctl reload nginx || true
fi

echo "OK: Jmaka removed."
