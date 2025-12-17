#!/usr/bin/env bash
set -euo pipefail

# If started without sudo, re-run with sudo automatically.
# We keep the original user HOME so the tarball can be stored in the user's directory.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This installer needs sudo. Re-running with sudo..."
  # Preserve the original user's HOME for defaults (~) and file access.
  exec sudo -E JMAKA_ORIG_USER="${USER:-}" JMAKA_ORIG_HOME="${HOME:-}" bash "$0" "$@"
fi

# Jmaka installer (wizard-friendly)
# What it does:
# - installs ASP.NET Core Runtime 10 into /opt/dotnet (if missing)
# - unpacks the app bundle to /var/www/jmaka/<name>/app
# - stores data in /var/www/jmaka/<name>/storage
# - creates and starts a systemd service listening on 127.0.0.1:<port>
# - nginx integration:
#     * AUTO (default): writes a snippet + injects an `include ...` into your existing vhost for the domain
#     * or prints a snippet for manual paste
#
# Usage:
# - interactive (recommended):
#     bash install.sh --interactive
# - non-interactive:
#     bash install.sh --name jmaka --port 5010 --tar /root/jmaka.tar.gz --domain example.com --path-prefix /jmaka/ --mount-mode basepath --nginx-action auto

# Identify original (non-root) user/home (important when running via sudo)
ORIG_USER="${JMAKA_ORIG_USER:-${SUDO_USER:-${USER:-}}}"
ORIG_HOME="${JMAKA_ORIG_HOME:-""}"
if [[ -z "$ORIG_HOME" && -n "$ORIG_USER" ]]; then
  ORIG_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6 || true)"
fi
if [[ -z "$ORIG_HOME" ]]; then
  ORIG_HOME="/root"
fi

NAME="jmaka"
PORT="5010"
# Can be a local path or an https:// URL.
# Default tarball location: user's home, so it can be downloaded without root.
APP_TAR="${ORIG_HOME}/jmaka.tar.gz"
BASE_DIR=""

# Optional interactive mode (for non-technical users)
INTERACTIVE=0

# Mount mode for subpath (/jmaka/):
# - basepath (recommended): app receives /jmaka/* and gets JMAKA_BASE_PATH=/jmaka
# - strip (legacy): nginx strips /jmaka, app runs at /
MOUNT_MODE="basepath"  # basepath|strip

# Nginx integration
# - auto: writes a snippet and injects `include ...` into an existing vhost for the domain (recommended)
# - print: prints snippet for manual paste
# - write-snippet: only writes snippet file (manual include)
# - none: don't touch nginx
NGINX_ACTION="auto"   # none|auto|print|write-snippet
NGINX_DOMAIN=""
NGINX_VHOST_FILE=""   # optional explicit path for auto-mode
PATH_PREFIX="/"       # / or /something/
RELOAD_NGINX="1"      # 0/1

prompt_default() {
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __default="$1"; shift

  local __val=""
  read -r -p "${__prompt} [${__default}]: " __val
  if [[ -z "${__val}" ]]; then
    __val="${__default}"
  fi
  printf -v "${__var}" '%s' "${__val}"
}

sanitize_instance_name() {
  # systemd unit names and Linux paths are much safer with ASCII only.
  # Keep: a-z, 0-9, dash. Convert to lowercase, replace anything else with dash, trim dashes.
  local raw="$1"

  # obvious user error: people paste /var/www/... into instance name
  if [[ "$raw" == /* || "$raw" == *"/"* || "$raw" == *"\\"* ]]; then
    echo ""
    return 0
  fi

  # Lowercase (ASCII only)
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  # Replace non [a-z0-9-] with '-'
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9-]+/-/g')"

  # Trim leading/trailing '-'
  raw="$(printf '%s' "$raw" | sed -E 's/^-+//; s/-+$//')"

  # Collapse multiple '-'
  raw="$(printf '%s' "$raw" | sed -E 's/-{2,}/-/g')"

  # Limit length
  raw="$(printf '%s' "$raw" | cut -c1-48)"

  echo "$raw"
}

ensure_safe_instance_name() {
  local before="$NAME"
  local after
  after="$(sanitize_instance_name "$before")"

  if [[ -z "$after" ]]; then
    echo "ERROR: instance name is invalid (or looks like a path). Use a slug like: jmaka, cholera-test" >&2
    exit 1
  fi

  if [[ "$after" != "$before" ]]; then
    echo "NOTE: instance name normalized: '$before' -> '$after'" >&2
    NAME="$after"
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: please run as root (use sudo)." >&2
    exit 1
  fi
}

expand_user_path() {
  # Expands ~ and ~/... using the ORIGINAL user's home (not /root).
  local p="$1"
  if [[ "$p" == "~" ]]; then
    echo "$ORIG_HOME"
    return
  fi
  if [[ "$p" == "~/"* ]]; then
    echo "$ORIG_HOME/${p:2}"
    return
  fi
  echo "$p"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_url() {
  local s="$1"
  [[ "$s" == http://* || "$s" == https://* ]]
}

stop_existing_service() {
  local service_name="$1"
  if systemctl list-unit-files 2>/dev/null | grep -qE "^${service_name}\.service"; then
    echo "Stopping existing service (safe reinstall): ${service_name}"
    systemctl stop "${service_name}" >/dev/null 2>&1 || true
  fi
}

download_bundle_if_url() {
  # If APP_TAR is a URL, download it to the given local path.
  local src="$1"
  local dst="$2"

  if is_url "$src"; then
    echo "Downloading app bundle to: $dst"
    curl -fsSL "$src" -o "$dst"
    APP_TAR="$dst"
  fi
}

require_cmd() {
  local c="$1"
  if ! have_cmd "$c"; then
    echo "ERROR: missing required command: $c" >&2
    exit 1
  fi
}

detect_platform() {
  # Prints a short banner and performs basic sanity checks.
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "Detected OS: ${PRETTY_NAME:-unknown}"

    if [[ "${ID:-}" != "ubuntu" ]]; then
      echo "WARNING: this installer is designed for Ubuntu 24+." >&2
    fi

    # Best-effort check; allow 24.04+.
    if [[ -n "${VERSION_ID:-}" ]]; then
      case "${VERSION_ID}" in
        24.*) : ;;
        25.*|26.*) : ;;
        *) echo "WARNING: VERSION_ID=${VERSION_ID}; expected Ubuntu 24+. Proceeding anyway." >&2 ;;
      esac
    fi
  else
    echo "WARNING: cannot detect OS (/etc/os-release not found)." >&2
  fi
}

ensure_packages() {
  # Minimal packages for this installer and port detection.
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl tar iproute2
}

ensure_nginx_if_needed() {
  if [[ "$RELOAD_NGINX" -ne 1 && "$NGINX_ACTION" != "write-snippet" && "$NGINX_ACTION" != "auto" ]]; then
    return 0
  fi

  if have_cmd nginx; then
    return 0
  fi

  echo "Nginx is not installed but nginx automation/reload was requested. Installing nginx..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx
}

normalize_path_prefix() {
  local p="$1"
  if [[ -z "$p" ]]; then
    p="/"
  fi
  if [[ "${p:0:1}" != "/" ]]; then
    p="/${p}"
  fi
  if [[ "$p" != "/" && "${p: -1}" != "/" ]]; then
    p="${p}/"
  fi
  echo "$p"
}

list_used_tcp_ports() {
  # Sorted unique list of LISTEN tcp ports (IPv4 + IPv6)
  # NOTE: requires `ss` (iproute2), which exists on Ubuntu by default.
  if command -v ss >/dev/null 2>&1; then
    ss -lntH 2>/dev/null \
      | awk '{print $4}' \
      | awk -F':' '{print $NF}' \
      | sed 's/\[//g; s/\]//g' \
      | grep -E '^[0-9]+$' \
      | sort -n \
      | uniq
  fi
}

is_port_used() {
  local p="$1"
  if [[ -z "$p" ]]; then return 1; fi
  list_used_tcp_ports | awk -v port="$p" '$1==port {found=1} END{exit found?0:1}'
}

print_used_ports_hint() {
  local ports
  ports="$(list_used_tcp_ports | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]$//')"
  echo "Used TCP listen ports on this server:"
  if [[ -z "$ports" ]]; then
    echo "  (could not detect)"
  else
    echo "  $ports"
  fi
  echo "Choose a free port for Jmaka (recommended range: 5000-5999)."
}

suggest_free_port() {
  # Suggest first free port in range [5000..5999]
  local p
  for p in $(seq 5000 5999); do
    if ! is_port_used "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

require_root

detect_platform

if [[ $# -eq 0 ]]; then
  INTERACTIVE=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=1; shift 1;;
    --name) NAME="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --tar) APP_TAR="$2"; shift 2;;
    --base-dir) BASE_DIR="$2"; shift 2;;

    --domain) NGINX_DOMAIN="$2"; shift 2;;
    --nginx-vhost-file) NGINX_VHOST_FILE="$2"; shift 2;;
    --path-prefix) PATH_PREFIX="$2"; shift 2;;
    --mount-mode) MOUNT_MODE="$2"; shift 2;;

    --nginx-action) NGINX_ACTION="$2"; shift 2;;
    --reload-nginx) RELOAD_NGINX=1; shift 1;;

    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

if [[ "$INTERACTIVE" -eq 1 ]]; then
  echo "Interactive setup:"
  prompt_default NAME "Instance name (slug, NOT a path)" "$NAME"
  ensure_safe_instance_name

  prompt_default BASE_DIR "Base dir for this instance" "${BASE_DIR:-/var/www/jmaka/${NAME}}"

  print_used_ports_hint
  _suggested_port=""
  _suggested_port="$(suggest_free_port || true)"
  if [[ -n "${_suggested_port}" ]]; then
    echo "Suggested free port: ${_suggested_port}"
    PORT="${_suggested_port}"
  else
    echo "WARNING: could not find a free port in 5000-5999; you must pick manually." >&2
  fi

  while true; do
    prompt_default PORT "Local port (127.0.0.1:PORT)" "$PORT"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
      echo "Port must be a number." >&2
      continue
    fi
    if [[ "$PORT" -lt 1024 ]]; then
      echo "Ports below 1024 are not recommended. Use 5000-5999." >&2
      continue
    fi
    if is_port_used "$PORT"; then
      echo "Port $PORT is already in use. Choose another." >&2
      continue
    fi
    break
  done

  prompt_default APP_TAR "Path to app bundle (.tar.gz)" "$APP_TAR"
  APP_TAR="$(expand_user_path "$APP_TAR")"
  prompt_default NGINX_DOMAIN "Domain/subdomain" "${NGINX_DOMAIN:-example.com}"
  prompt_default PATH_PREFIX "Path prefix (use / for root, or /jmaka/)" "${PATH_PREFIX}"

  PATH_PREFIX="$(normalize_path_prefix "$PATH_PREFIX")"
  if [[ "$PATH_PREFIX" != "/" ]]; then
    echo "Mount mode for subpath:"
    echo "  1) base-path mode (recommended)  - app gets /jmaka/*, sets JMAKA_BASE_PATH=/jmaka"
    echo "  2) strip-prefix mode (legacy)    - nginx removes /jmaka, app runs at /"
    read -r -p "Choose [1-2] (default 1): " _mm
    if [[ -z "${_mm}" || "${_mm}" == "1" ]]; then
      MOUNT_MODE="basepath"
    else
      MOUNT_MODE="strip"
    fi
  fi

  echo "Nginx automation:"
  echo "  1) AUTO (recommended): write snippet + inject include into your existing vhost"
  echo "  2) Just PRINT snippet (manual paste)"
  echo "  3) WRITE snippet file only (manual include)"
  echo "  4) None"
  read -r -p "Choose [1-4] (default 1): " _na
  if [[ -z "${_na}" ]]; then _na="1"; fi
  case "${_na}" in
    1) NGINX_ACTION="auto";;
    2) NGINX_ACTION="print";;
    3) NGINX_ACTION="write-snippet";;
    4) NGINX_ACTION="none";;
    *) NGINX_ACTION="auto";;
  esac

if [[ "$NGINX_ACTION" == "auto" ]]; then
    echo "Reload nginx after changes?"
    read -r -p "Reload nginx? [Y/n]: " _rn
    if [[ -z "${_rn}" || "${_rn}" =~ ^[Yy]$ ]]; then RELOAD_NGINX=1; else RELOAD_NGINX=0; fi
  fi
fi

PATH_PREFIX="$(normalize_path_prefix "$PATH_PREFIX")"
APP_TAR="$(expand_user_path "$APP_TAR")"

if [[ "$MOUNT_MODE" != "basepath" && "$MOUNT_MODE" != "strip" ]]; then
  echo "ERROR: --mount-mode must be basepath or strip" >&2
  exit 1
fi
if [[ "$PATH_PREFIX" == "/" ]]; then
  # no subpath, mount mode doesn't matter
  MOUNT_MODE="basepath"
fi


if [[ -z "$NAME" ]]; then
  echo "ERROR: --name is required" >&2
  exit 1
fi

ensure_safe_instance_name

# Default base dir is /var/www/jmaka/<name> (one directory per instance)
if [[ -z "$BASE_DIR" ]]; then
  BASE_DIR="/var/www/jmaka/${NAME}"
fi

SERVICE_NAME="jmaka-${NAME}"
stop_existing_service "$SERVICE_NAME"

# ----- validate port -----
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --port must be a number" >&2
  exit 1
fi

if [[ "$PORT" -lt 1024 ]]; then
  echo "ERROR: ports below 1024 are not recommended. Use 5000-5999." >&2
  exit 1
fi

if is_port_used "$PORT"; then
  echo "ERROR: port $PORT is already in use (pick another)." >&2
  exit 1
fi

# If --tar is a URL, download it to the default local path.
if is_url "$APP_TAR"; then
  download_bundle_if_url "$APP_TAR" "${ORIG_HOME}/jmaka.tar.gz"
fi

if [[ ! -f "$APP_TAR" ]]; then
  echo "ERROR: app bundle not found at: $APP_TAR" >&2
  echo "Provide a local path OR an https:// URL. Recommended local path: ${ORIG_HOME}/jmaka.tar.gz" >&2
  exit 1
fi

ensure_packages

# service user (shared for all instances)
if ! id -u jmaka >/dev/null 2>&1; then
  useradd --system --home /var/lib/jmaka --create-home --shell /usr/sbin/nologin jmaka
fi

# Install .NET ASP.NET Core Runtime 10 into /opt/dotnet (no apt dependency)
DOTNET_DIR="/opt/dotnet"
if [[ ! -x "$DOTNET_DIR/dotnet" ]]; then
  require_cmd curl

  mkdir -p "$DOTNET_DIR"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  /tmp/dotnet-install.sh --channel 10.0 --runtime aspnetcore --install-dir "$DOTNET_DIR"
fi

APP_DIR="${BASE_DIR}/app"
DATA_DIR="${BASE_DIR}/storage"

mkdir -p "$APP_DIR" "$DATA_DIR"

SERVICE_NAME="jmaka-${NAME}"

# App files are read-only and owned by root.
chown -R root:root "$APP_DIR"
chmod -R a=rX "$APP_DIR"

# Storage must be writable by the service user.
chown -R jmaka:jmaka "$DATA_DIR"
chmod -R u+rwX,go-rwx "$DATA_DIR"

rm -rf "$APP_DIR"/*
tar -xzf "$APP_TAR" -C "$APP_DIR"
chown -R root:root "$APP_DIR"
chmod -R a=rX "$APP_DIR"

# Base path for app: "/" or "/jmaka" (without trailing slash)
BASE_PATH_ENV="/"
if [[ "$PATH_PREFIX" != "/" && "$MOUNT_MODE" == "basepath" ]]; then
  BASE_PATH_ENV="${PATH_PREFIX%/}"
fi

cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Jmaka API (${NAME})
After=network.target

[Service]
WorkingDirectory=${APP_DIR}
ExecStart=${DOTNET_DIR}/dotnet ${APP_DIR}/Jmaka.Api.dll
Restart=always
RestartSec=10
KillSignal=SIGINT
User=jmaka
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://127.0.0.1:${PORT}
Environment=DOTNET_ROOT=${DOTNET_DIR}
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=JMAKA_STORAGE_ROOT=${DATA_DIR}
Environment=JMAKA_BASE_PATH=${BASE_PATH_ENV}

[Install]
WantedBy=multi-user.target
EOF

require_cmd systemctl
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo ""
echo "OK. Service started: ${SERVICE_NAME} (listening on 127.0.0.1:${PORT})"
echo "Installed to: ${BASE_DIR}"
echo "  app:     ${APP_DIR}"
echo "  storage: ${DATA_DIR}"
echo "Status: systemctl status ${SERVICE_NAME} --no-pager"
echo "Logs:   journalctl -u ${SERVICE_NAME} -n 200 --no-pager"
nginx_snippet() {
  if [[ "$PATH_PREFIX" == "/" ]]; then
    cat <<NGINX
client_max_body_size 80m;
location / {
    proxy_redirect off;
    proxy_pass         http://127.0.0.1:${PORT};
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection keep-alive;
    proxy_set_header   Host \$host;
    proxy_cache_bypass \$http_upgrade;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
}
NGINX
  else
    # Also redirect /prefix (no trailing slash) -> /prefix/ so users can type short URLs.
    prefix_no_slash="${PATH_PREFIX%/}"

    if [[ "$MOUNT_MODE" == "basepath" ]]; then
      cat <<NGINX
client_max_body_size 80m;

location = ${prefix_no_slash} {
    return 301 ${PATH_PREFIX};
}

location ^~ ${PATH_PREFIX} {
    proxy_redirect off;

    # base-path mode: app is configured with JMAKA_BASE_PATH=${prefix_no_slash}
    # so we MUST pass the full URI including the prefix to the upstream.
    # Therefore NO trailing slash in proxy_pass here.
    proxy_pass         http://127.0.0.1:${PORT};

    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection keep-alive;
    proxy_set_header   Host \$host;
    proxy_cache_bypass \$http_upgrade;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
}
NGINX
    else
      cat <<NGINX
client_max_body_size 80m;

location = ${prefix_no_slash} {
    return 301 ${PATH_PREFIX};
}

location ^~ ${PATH_PREFIX} {
    proxy_redirect off;

    # strip-prefix mode: nginx removes the prefix before proxying.
    # Therefore proxy_pass MUST have a trailing slash.
    proxy_pass         http://127.0.0.1:${PORT}/;

    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection keep-alive;
    proxy_set_header   Host \$host;
    proxy_cache_bypass \$http_upgrade;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
}
NGINX
    fi
  fi
}


write_nginx_location_snippet_file() {
  ensure_nginx_if_needed
  local loc_path="/etc/nginx/snippets/jmaka-${NAME}.location.conf"
  echo "Writing nginx location snippet: ${loc_path}"
  mkdir -p /etc/nginx/snippets
  nginx_snippet >"${loc_path}"
}

auto_configure_nginx() {
  if [[ -z "$NGINX_DOMAIN" || "$NGINX_DOMAIN" == "example.com" ]]; then
    echo "ERROR: nginx auto-config requires a real domain (server_name)." >&2
    exit 1
  fi

  write_nginx_location_snippet_file

  local vhost_file="${NGINX_VHOST_FILE:-}" 
  if [[ -z "$vhost_file" ]]; then
    vhost_file="$(select_nginx_vhost_file)"
  fi

  if [[ -z "$vhost_file" ]]; then
    echo "ERROR: could not find an existing nginx vhost for domain '${NGINX_DOMAIN}'." >&2
    echo "Tip: run with --nginx-action print, or specify --nginx-vhost-file /path/to/vhost.conf" >&2
    exit 1
  fi

  echo "Using nginx vhost file: ${vhost_file}"
  inject_include_into_vhost "$vhost_file"

  if [[ "$RELOAD_NGINX" -eq 1 ]]; then
    maybe_reload_nginx
  fi
}

select_nginx_vhost_file() {
  # Find a vhost file that contains a server_name matching NGINX_DOMAIN.
  # Prefer /etc/nginx/sites-enabled because that's what is active.
  local matches
  matches="$(grep -RIl --include='*.conf' -E "^[[:space:]]*server_name[[:space:]].*\b${NGINX_DOMAIN}\b" /etc/nginx/sites-enabled 2>/dev/null || true)"
  if [[ -z "$matches" ]]; then
    matches="$(grep -RIl --include='*.conf' -E "^[[:space:]]*server_name[[:space:]].*\b${NGINX_DOMAIN}\b" /etc/nginx/sites-available 2>/dev/null || true)"
  fi

  if [[ -z "$matches" ]]; then
    echo ""
    return 0
  fi

  # If multiple matches, prefer HTTPS vhost (listen 443 ... ssl) if present.
  best=""
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    # Score heuristic:
    # 2 = has listen 443 and ssl
    # 1 = has listen 443
    # 0 = otherwise
    score=0
    if grep -qE '^[[:space:]]*listen[[:space:]]+\[?::\]?\s*443\b' "$f"; then
      score=1
      if grep -qE '^[[:space:]]*listen[[:space:]]+.*\b443\b.*\bssl\b' "$f"; then
        score=2
      fi
    fi

    if [[ -z "$best" || "$score" -gt "$best_score" ]]; then
      best="$f"
      best_score="$score"
    fi
  done <<<"$matches"

  # If interactive and multiple, ask (but show best as default).
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
    if [[ "$count" -gt 1 ]]; then
      echo "Multiple nginx vhost files match domain '${NGINX_DOMAIN}':" >&2
      echo "(Tip: for HTTPS routing you usually want the 443/ssl vhost)" >&2
      i=1
      def=1
      while IFS= read -r f; do
        mark=""
        if [[ "$f" == "$best" ]]; then
          mark=" (recommended)"
          def="$i"
        fi
        echo "  ${i}) ${f}${mark}" >&2
        i=$((i+1))
      done <<<"$matches"
      read -r -p "Choose [1-${count}] (default ${def}): " pick
      if [[ -z "$pick" ]]; then pick="$def"; fi
      echo "$(printf '%s\n' "$matches" | sed -n "${pick}p")"
      return 0
    fi
  fi

  echo "$best"
}

inject_include_into_vhost() {
  local vhost_file="$1"
  local include_line="include /etc/nginx/snippets/jmaka-${NAME}.location.conf;"

  if [[ ! -f "$vhost_file" ]]; then
    echo "ERROR: nginx vhost file not found: $vhost_file" >&2
    exit 1
  fi

  # Backup before editing
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$vhost_file" "${vhost_file}.bak.${ts}"

  # If already included anywhere, do nothing.
  if grep -qF "$include_line" "$vhost_file"; then
    echo "Nginx vhost already includes jmaka snippet."
    return 0
  fi

  tmp="${vhost_file}.tmp.${ts}"

  awk -v domain="$NGINX_DOMAIN" -v inc="$include_line" '
    function count_braces(s,  t, o, c) {
      t=s; o=gsub(/\{/, "", t); t=s; c=gsub(/\}/, "", t); return o - c
    }
    BEGIN { in_server=0; depth=0; target=0; inserted=0 }
    {
      line=$0
      if (!in_server && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
        in_server=1; depth=1; target=0; inserted=0
        print line
        next
      }

      if (in_server) {
        if (!target && line ~ /^[[:space:]]*server_name[[:space:]].*;/ && line ~ domain) {
          target=1
          print line
          if (!inserted) {
            print "    " inc
            inserted=1
          }
          depth += count_braces(line)
          if (depth <= 0) { in_server=0 }
          next
        }

        depth += count_braces(line)
        if (depth <= 0) { in_server=0 }
      }

      print line
    }
  ' "$vhost_file" >"$tmp"

  mv "$tmp" "$vhost_file"
}

maybe_reload_nginx() {
  if [[ "$RELOAD_NGINX" -ne 1 ]]; then
    return 0
  fi

  ensure_nginx_if_needed
  require_cmd nginx
  require_cmd systemctl

  echo "Reloading nginx..."
  nginx -t
  systemctl reload nginx
}

echo ""
case "$NGINX_ACTION" in
  none)
    ;;
  auto)
    auto_configure_nginx
    ;;
  print)
    echo "Nginx config to paste (domain: ${NGINX_DOMAIN}, prefix: ${PATH_PREFIX})"
    echo "Paste this INSIDE the existing server block."
    echo "IMPORTANT: Put it ABOVE a catch-all 'location /' block, and use '^~' for /jmaka/."
    echo ""
    nginx_snippet
    ;;
  write-snippet)
    write_nginx_location_snippet_file
    echo ""
    echo "Now include it in your server block: include /etc/nginx/snippets/jmaka-${NAME}.location.conf;"
    echo "(Place the include above any catch-all location /)"
    if [[ "$RELOAD_NGINX" -eq 1 ]]; then
      maybe_reload_nginx
    fi
    ;;
  *)
    echo "Unknown NGINX_ACTION: $NGINX_ACTION" >&2
    ;;
esac
