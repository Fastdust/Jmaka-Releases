#!/usr/bin/env bash
set -euo pipefail

# If started without sudo, re-run with sudo automatically.
# We keep the original user HOME so the tarball can be stored in the user's directory.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This installer needs sudo. Re-running with sudo..."
  # Preserve the original user's HOME for defaults (~) and file access.
  exec sudo -E JMAKA_ORIG_USER="${USER:-}" JMAKA_ORIG_HOME="${HOME:-}" bash "$0" "$@"
fi

# Jmaka Ubuntu 24 installer (wizard-friendly)
# What it does:
# - installs ASP.NET Core Runtime 10 into /opt/dotnet (if missing)
# - unpacks the app bundle to /var/www/jmaka/<name>/app
# - stores data in /var/www/jmaka/<name>/storage (upload/resized/preview/data)
# - creates and starts a systemd service listening on 127.0.0.1:<port>
# - can print OR write an nginx snippet/vhost file (optional)
#
# Usage:
# - interactive (recommended for first time):
#     sudo bash deploy/ubuntu24/install.sh
# - non-interactive:
#     sudo bash deploy/ubuntu24/install.sh --name a --port 5010 --tar /var/www/jmaka/_bundles/jmaka.tar.gz --domain a.example.com --path-prefix /

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
# Default tarball location: user's home, so it can be downloaded without root.
APP_TAR="${ORIG_HOME}/jmaka.tar.gz"
BASE_DIR=""

# Optional interactive mode (for non-technical users)
INTERACTIVE=0

# Nginx integration
NGINX_ACTION="print"   # none|print|write-snippet|write-vhost
NGINX_DOMAIN=""
PATH_PREFIX="/"        # / or /something/
TLS_LISTEN_PORT="443"  # 443, 7443, etc
TLS_PROXY_PROTOCOL="0" # 0/1
SSL_CERT=""
SSL_KEY=""
ENABLE_NGINX_SITE="0"  # 0/1 (only for write-vhost)
RELOAD_NGINX="0"       # 0/1

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
  if [[ "$RELOAD_NGINX" -ne 1 && "$NGINX_ACTION" != "write-snippet" && "$NGINX_ACTION" != "write-vhost" ]]; then
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
    --path-prefix) PATH_PREFIX="$2"; shift 2;;

    --nginx-action) NGINX_ACTION="$2"; shift 2;;
    --tls-listen-port) TLS_LISTEN_PORT="$2"; shift 2;;
    --tls-proxy-protocol) TLS_PROXY_PROTOCOL="$2"; shift 2;;
    --ssl-cert) SSL_CERT="$2"; shift 2;;
    --ssl-key) SSL_KEY="$2"; shift 2;;
    --enable-nginx-site) ENABLE_NGINX_SITE=1; shift 1;;
    --reload-nginx) RELOAD_NGINX=1; shift 1;;

    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

if [[ "$INTERACTIVE" -eq 1 ]]; then
  echo "Interactive setup:"
  prompt_default NAME "Instance name" "$NAME"

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
  prompt_default BASE_DIR "Base dir for this instance" "${BASE_DIR:-/var/www/jmaka/${NAME}}"
  prompt_default NGINX_DOMAIN "Domain/subdomain" "${NGINX_DOMAIN:-example.com}"
  prompt_default PATH_PREFIX "Path prefix (use / for root, or /jmaka/)" "${PATH_PREFIX}"
  prompt_default TLS_LISTEN_PORT "Nginx TLS listen port (443, 7443, ...)" "${TLS_LISTEN_PORT}"

  echo "Use proxy_protocol on the listen line?"
  echo "  0) no"
  echo "  1) yes"
  read -r -p "Choose [0-1] (default ${TLS_PROXY_PROTOCOL}): " _pp
  if [[ -n "${_pp}" ]]; then TLS_PROXY_PROTOCOL="${_pp}"; fi

  # Default LetsEncrypt paths for convenience
  if [[ -z "$SSL_CERT" ]]; then
    SSL_CERT="/etc/letsencrypt/live/${NGINX_DOMAIN}/fullchain.pem"
  fi
  if [[ -z "$SSL_KEY" ]]; then
    SSL_KEY="/etc/letsencrypt/live/${NGINX_DOMAIN}/privkey.pem"
  fi
  prompt_default SSL_CERT "ssl_certificate" "$SSL_CERT"
  prompt_default SSL_KEY "ssl_certificate_key" "$SSL_KEY"

  echo "Nginx automation:"
  echo "  1) Just PRINT config/snippet (recommended)"
  echo "  2) WRITE snippet file (/etc/nginx/snippets/jmaka-<name>.conf)"
  echo "  3) WRITE full vhost file (/etc/nginx/sites-available/jmaka-<name>.conf)"
  echo "  4) None"
  read -r -p "Choose [1-4] (default 1): " _na
  if [[ -z "${_na}" ]]; then _na="1"; fi
  case "${_na}" in
    1) NGINX_ACTION="print";;
    2) NGINX_ACTION="write-snippet";;
    3) NGINX_ACTION="write-vhost";;
    4) NGINX_ACTION="none";;
    *) NGINX_ACTION="print";;
  esac

  if [[ "$NGINX_ACTION" == "write-vhost" ]]; then
    echo "Enable this site (symlink to sites-enabled)?"
    read -r -p "Enable? [y/N]: " _en
    if [[ "${_en}" =~ ^[Yy]$ ]]; then ENABLE_NGINX_SITE=1; fi
  fi

  echo "Reload nginx after changes?"
  read -r -p "Reload nginx? [y/N]: " _rn
  if [[ "${_rn}" =~ ^[Yy]$ ]]; then RELOAD_NGINX=1; fi
fi

PATH_PREFIX="$(normalize_path_prefix "$PATH_PREFIX")"
APP_TAR="$(expand_user_path "$APP_TAR")"

if [[ -z "$NAME" ]]; then
  echo "ERROR: --name is required" >&2
  exit 1
fi

# Default base dir is /var/www/jmaka/<name> (one directory per instance)
if [[ -z "$BASE_DIR" ]]; then
  BASE_DIR="/var/www/jmaka/${NAME}"
fi

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

if [[ ! -f "$APP_TAR" ]]; then
  echo "ERROR: app bundle not found at: $APP_TAR" >&2
  echo "Download it first (recommended) to: ${ORIG_HOME}/jmaka.tar.gz" >&2
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

# App files are read-only and owned by root.
chown -R root:root "$BASE_DIR"
chmod -R a=rX "$APP_DIR"

# Storage must be writable by the service user.
chown -R jmaka:jmaka "$DATA_DIR"
chmod -R u+rwX,go-rwx "$DATA_DIR"

rm -rf "$APP_DIR"/*
tar -xzf "$APP_TAR" -C "$APP_DIR"
chown -R root:root "$APP_DIR"
chmod -R a=rX "$APP_DIR"

SERVICE_NAME="jmaka-${NAME}"

# Base path for app: "/" or "/jmaka" (without trailing slash)
BASE_PATH_ENV="/"
if [[ "$PATH_PREFIX" != "/" ]]; then
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
    cat <<NGINX
client_max_body_size 80m;
location ${PATH_PREFIX} {
    proxy_redirect off;

    # App is configured with JMAKA_BASE_PATH=${PATH_PREFIX%/}
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
  fi
}

write_nginx_snippet_file() {
  ensure_nginx_if_needed
  local snippet_path="/etc/nginx/snippets/jmaka-${NAME}.conf"
  echo "Writing nginx snippet: ${snippet_path}"
  mkdir -p /etc/nginx/snippets
  nginx_snippet >"${snippet_path}"
}

write_nginx_vhost_file() {
  ensure_nginx_if_needed

  if [[ -z "$SSL_CERT" || -z "$SSL_KEY" ]]; then
    echo "ERROR: ssl cert/key paths are required for write-vhost." >&2
    exit 1
  fi
  if [[ ! -f "$SSL_CERT" ]]; then
    echo "WARNING: ssl_certificate does not exist: $SSL_CERT" >&2
  fi
  if [[ ! -f "$SSL_KEY" ]]; then
    echo "WARNING: ssl_certificate_key does not exist: $SSL_KEY" >&2
  fi

  local vhost_path="/etc/nginx/sites-available/jmaka-${NAME}.conf"
  echo "Writing nginx vhost: ${vhost_path}"
  mkdir -p /etc/nginx/sites-available

  local listen_line="listen ${TLS_LISTEN_PORT} ssl http2"
  local listen_line_v6="listen [::]:${TLS_LISTEN_PORT} ssl http2"
  if [[ "$TLS_PROXY_PROTOCOL" == "1" ]]; then
    listen_line="${listen_line} proxy_protocol"
    listen_line_v6="${listen_line_v6} proxy_protocol"
  fi

  cat >"${vhost_path}" <<EOF
server {
    server_tokens off;

    server_name ${NGINX_DOMAIN};
    ${listen_line};
    ${listen_line_v6};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    # Optional hardening (matches your style)
    if (\$host !~* ^(.+\.)?${NGINX_DOMAIN//./\.}\$ ) { return 444; }

    include /etc/nginx/snippets/jmaka-${NAME}.location.conf;
}
EOF

  # location snippet file (kept separate so you can reuse it inside existing vhosts too)
  local loc_path="/etc/nginx/snippets/jmaka-${NAME}.location.conf"
  echo "Writing nginx location snippet: ${loc_path}"
  nginx_snippet >"${loc_path}"
}

maybe_enable_site() {
  if [[ "$ENABLE_NGINX_SITE" -ne 1 ]]; then
    return 0
  fi
  local vhost_path="/etc/nginx/sites-available/jmaka-${NAME}.conf"
  local link_path="/etc/nginx/sites-enabled/jmaka-${NAME}.conf"
  echo "Enabling site: ${link_path} -> ${vhost_path}"
  mkdir -p /etc/nginx/sites-enabled
  ln -sf "${vhost_path}" "${link_path}"
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
  print)
    echo "Nginx config to paste (domain: ${NGINX_DOMAIN}, prefix: ${PATH_PREFIX})"
    echo "Paste this INSIDE the existing server block."
    echo "IMPORTANT: If you paste into a big config, put it ABOVE a catch-all 'location /' block."
    echo ""
    nginx_snippet
    ;;
  write-snippet)
    write_nginx_snippet_file
    maybe_reload_nginx
    echo ""
    echo "Now include it in your server block: include /etc/nginx/snippets/jmaka-${NAME}.conf;"
    echo "(Place the include above any catch-all location /)"
    ;;
  write-vhost)
    write_nginx_vhost_file
    maybe_enable_site
    maybe_reload_nginx
    echo ""
    echo "Vhost created: /etc/nginx/sites-available/jmaka-${NAME}.conf"
    if [[ "$ENABLE_NGINX_SITE" -ne 1 ]]; then
      echo "To enable: ln -s /etc/nginx/sites-available/jmaka-${NAME}.conf /etc/nginx/sites-enabled/jmaka-${NAME}.conf"
      echo "Then: nginx -t && systemctl reload nginx"
    fi
    ;;
  *)
    echo "Unknown NGINX_ACTION: $NGINX_ACTION" >&2
    ;;
esac
