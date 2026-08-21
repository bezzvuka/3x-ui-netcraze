#!/opt/bin/bash
set -Eeuo pipefail

VERSION="v3.6.0-netcraze.1"
BUNDLE_URL="https://github.com/bezzvuka/3x-ui-netcraze/releases/download/${VERSION}/x-ui-netcraze-arm64.tar.gz"
BUNDLE_SHA256="1a981d09228bae3c851bbc63979920678e9cbd12f7221dee078d4a7420a42b91"
INSTALL_DIR="/opt/3x-ui"
DB_DIR="/opt/etc/x-ui"
LOG_DIR="/opt/var/log/x-ui"
INIT_SCRIPT="/opt/etc/init.d/S99x-ui"
STAGE_DIR="/opt/tmp/3xui-install.$$"

info() {
    printf '\033[1;32m[3x-ui] %s\033[0m\n' "$*"
}

fail() {
    printf '\033[1;31m[3x-ui] ERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${STAGE_DIR:-}" && -d "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
}
trap cleanup EXIT

[[ "$(id -u)" == "0" ]] || fail "Run this installer as root"
[[ "$(uname -m)" == "aarch64" ]] || fail "Only aarch64 Netcraze routers are supported"
[[ -d /opt && -w /opt ]] || fail "/opt is unavailable or read-only; initialize Entware first"

ROOT_DEVICE="$(df -P / | awk 'NR == 2 { print $1 }')"
OPT_DEVICE="$(df -P /opt | awk 'NR == 2 { print $1 }')"
[[ -n "$OPT_DEVICE" && "$OPT_DEVICE" != "$ROOT_DEVICE" ]] || fail "/opt is not mounted on an external drive"

AVAILABLE_KB="$(df -Pk /opt | awk 'NR == 2 { print $4 }')"
[[ "${AVAILABLE_KB:-0}" -ge 700000 ]] || fail "At least 700 MB free on /opt is required for installation and rollback"

OPKG="$(command -v opkg || true)"
[[ -n "$OPKG" ]] || fail "Entware opkg was not found"

info "Preparing Entware packages"
"$OPKG" update
"$OPKG" install bash wget-ssl ca-bundle ca-certificates tar gzip

WGET="$(command -v wget || true)"
[[ -n "$WGET" ]] || fail "wget was not installed"
command -v sha256sum >/dev/null || fail "sha256sum is unavailable"

mkdir -p "$STAGE_DIR" "$DB_DIR" "$LOG_DIR" /opt/var/run
BUNDLE="$STAGE_DIR/x-ui-netcraze-arm64.tar.gz"

info "Downloading 3x-ui ${VERSION}"
"$WGET" -q --show-progress -O "$BUNDLE" "$BUNDLE_URL"

ACTUAL_SHA256="$(sha256sum "$BUNDLE" | awk '{ print $1 }')"
[[ "$ACTUAL_SHA256" == "$BUNDLE_SHA256" ]] || fail "Bundle checksum mismatch"

info "Extracting and validating the bundle"
tar -xzf "$BUNDLE" -C "$STAGE_DIR"
chmod 755 "$STAGE_DIR/x-ui/x-ui" "$STAGE_DIR/x-ui/x-ui.sh" "$STAGE_DIR/x-ui/bin/xray-linux-arm64"
[[ "$($STAGE_DIR/x-ui/x-ui -v)" == "3.6.0" ]] || fail "The bundled panel binary failed its version check"
"$STAGE_DIR/x-ui/bin/xray-linux-arm64" version >/dev/null || fail "The bundled Xray binary failed its version check"

FRESH_INSTALL=0
[[ -s "$DB_DIR/x-ui.db" ]] || FRESH_INSTALL=1
BACKUP_DIR=""

if [[ -x "$INIT_SCRIPT" ]]; then
    "$INIT_SCRIPT" stop || true
fi

if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="/opt/3x-ui.rollback.$(date +%Y%m%d-%H%M%S)"
    info "Saving the current installation to ${BACKUP_DIR}"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
fi

mv "$STAGE_DIR/x-ui" "$INSTALL_DIR"

cat >"$INIT_SCRIPT" <<'INIT'
#!/bin/sh
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export XUI_DB_FOLDER=/opt/etc/x-ui
export XUI_BIN_FOLDER=/opt/3x-ui/bin
export XUI_LOG_FOLDER=/opt/var/log/x-ui
export XUI_ENABLE_FAIL2BAN=false
export XUI_DISK_PATH=/opt
PID=/opt/var/run/x-ui.pid

status() {
    [ -s "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null
}

start() {
    status && { echo "3x-ui already running"; return 0; }
    cd /opt/3x-ui || return 1
    ./x-ui run >>/opt/var/log/x-ui/service.log 2>&1 &
    echo $! >"$PID"
    sleep 3
    status && echo "3x-ui started"
}

stop() {
    if status; then
        kill "$(cat "$PID")" 2>/dev/null || true
        sleep 2
    fi
    rm -f "$PID"
    echo "3x-ui stopped"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status|check) status && echo "3x-ui running" || { echo "3x-ui stopped"; exit 1; } ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
INIT
chmod 755 "$INIT_SCRIPT"

export XUI_DB_FOLDER="$DB_DIR"
export XUI_BIN_FOLDER="$INSTALL_DIR/bin"
export XUI_LOG_FOLDER="$LOG_DIR"
export XUI_ENABLE_FAIL2BAN=false
export XUI_DISK_PATH=/opt

PANEL_PORT=2053
PANEL_USER=""
PANEL_PASSWORD=""
WEB_PATH=""

if [[ "$FRESH_INSTALL" == "1" ]]; then
    PANEL_USER="xuiadmin"
    PANEL_PASSWORD="$(od -An -N 12 -tx1 /dev/urandom | tr -d ' \n')"
    WEB_PATH="$(od -An -N 8 -tx1 /dev/urandom | tr -d ' \n')"
    LAN_IP="$(ip -4 addr show 2>/dev/null | awk '/inet / { ip=$2; sub("/.*", "", ip); if (ip ~ /^10\./ || ip ~ /^192\.168\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) { print ip; exit } }')"
    LISTEN_IP="${LAN_IP:-0.0.0.0}"
    "$INSTALL_DIR/x-ui" setting -username "$PANEL_USER" -password "$PANEL_PASSWORD" -port "$PANEL_PORT" -listenIP "$LISTEN_IP" -webBasePath "/$WEB_PATH/"
fi

if ! "$INIT_SCRIPT" start || ! "$INIT_SCRIPT" status >/dev/null; then
    printf 'New installation failed; restoring the previous version\n' >&2
    "$INIT_SCRIPT" stop || true
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf -- "$INSTALL_DIR"
        mv "$BACKUP_DIR" "$INSTALL_DIR"
        "$INIT_SCRIPT" start || true
    fi
    fail "3x-ui failed to start"
fi

info "Installation completed successfully"
printf 'Data: %s\nLogs: %s\nDisk metrics: /opt\n' "$DB_DIR" "$LOG_DIR"
if [[ "$FRESH_INSTALL" == "1" ]]; then
    printf '\nPanel URL: http://%s:%s/%s/\nUsername: %s\nPassword: %s\n' "${LAN_IP:-ROUTER_IP}" "$PANEL_PORT" "$WEB_PATH" "$PANEL_USER" "$PANEL_PASSWORD"
else
    printf 'Existing database and credentials were preserved.\n'
fi
if [[ -n "$BACKUP_DIR" ]]; then
    printf 'Rollback copy: %s\n' "$BACKUP_DIR"
fi
