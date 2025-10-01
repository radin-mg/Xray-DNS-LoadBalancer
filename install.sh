#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

cleanup() {
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run as root" >&2
    exit 1
fi

if [[ ! -e /etc/os-release ]]; then
    echo "[ERROR] Unsupported system" >&2
    exit 1
fi
. /etc/os-release
if [[ $ID != "ubuntu" || ( $VERSION_ID != "22.04" && $VERSION_ID != "24.04" ) ]]; then
    echo "[ERROR] Ubuntu 22.04 or 24.04 required" >&2
    exit 1
fi

BASE_DIR="/opt/xray-dns"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR=$(mktemp -d)
umask 077

REQUIRED_FILES=(
    "xray-dns.sh"
    "bot.sh"
    "helpers.sh"
    "templates/socks-template.json"
    "logrotate.conf"
    "systemd/xray-dns.service"
    "systemd/xray-dns.timer"
    "systemd/xray-dns-rotator.service"
    "systemd/xray-dns-rotator.timer"
    "systemd/xray-dns-bot.service"
)

ensure_repo_payload() {
    local required
    for required in "${REQUIRED_FILES[@]}"; do
        if [[ ! -e "$REPO_DIR/$required" ]]; then
            download_repo_payload
            break
        fi
    done
    for required in "${REQUIRED_FILES[@]}"; do
        if [[ ! -e "$REPO_DIR/$required" ]]; then
            echo "[ERROR] Required installer file '$required' not found in $REPO_DIR" >&2
            exit 1
        fi
    done
}

download_repo_payload() {
    local repo_slug="${XRAY_DNS_REPO_SLUG:-radin-mg/Xray-DNS-LoadBalancer}"
    local api_url="https://api.github.com/repos/$repo_slug/releases/latest"
    local release_json=""
    release_json=$(curl -fsSL "$api_url")
    local tarball_url
    tarball_url=$(grep -Eo '"tarball_url"\s*:\s*"[^"]+"' <<<"$release_json" | head -n1 | cut -d '"' -f4)
    if [[ -z "$tarball_url" ]]; then
        local default_branch
        default_branch=$(grep -Eo '"default_branch"\s*:\s*"[^"]+"' <<<"$release_json" | head -n1 | cut -d '"' -f4)
        default_branch=${default_branch:-main}
        tarball_url="https://codeload.github.com/$repo_slug/tar.gz/refs/heads/$default_branch"
    fi
    if [[ -z "$tarball_url" ]]; then
        echo "[ERROR] Unable to determine repository tarball URL for $repo_slug" >&2
        exit 1
    fi
    local repo_tmp="$TMPDIR/repo"
    mkdir -p "$repo_tmp"
    local archive="$TMPDIR/repo.tar.gz"
    curl -fsSL "$tarball_url" -o "$archive"
    tar -xzf "$archive" --strip-components=1 -C "$repo_tmp"
    REPO_DIR="$repo_tmp"
}

ensure_repo_payload

APT_PACKAGES=(curl jq sed gawk iproute2 tar ca-certificates logrotate systemd unzip uuid-runtime)

apt-get update
apt-get install -y "${APT_PACKAGES[@]}"

install_xray() {
    local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local release_json
    release_json=$(curl -fsSL "$api_url")
    local asset_url
    asset_url=$(jq -r '.assets[] | select(.name | test("linux-64.zip$")) | .browser_download_url' <<<"$release_json" | head -n1)
    if [[ -z "$asset_url" ]]; then
        echo "[ERROR] Unable to determine Xray release" >&2
        exit 1
    fi
    local archive="$TMPDIR/xray.zip"
    curl -fsSL "$asset_url" -o "$archive"
    unzip -q -d "$TMPDIR/xray" "$archive"
    install -m 0755 "$TMPDIR/xray/xray" /usr/local/bin/xray
}

if ! command -v xray >/dev/null 2>&1; then
    install_xray
fi

mkdir -p "$BASE_DIR" "$BASE_DIR/state" "$BASE_DIR/logs" "$BASE_DIR/configs" "$BASE_DIR/templates"
chmod 700 "$BASE_DIR" "$BASE_DIR/state"
chmod 750 "$BASE_DIR/logs"
chmod 750 "$BASE_DIR/configs"

install -m 0755 "$REPO_DIR/xray-dns.sh" "$BASE_DIR/xray-dns.sh"
install -m 0755 "$REPO_DIR/bot.sh" "$BASE_DIR/bot.sh"
install -m 0644 "$REPO_DIR/helpers.sh" "$BASE_DIR/helpers.sh"
install -m 0644 "$REPO_DIR/templates/socks-template.json" "$BASE_DIR/templates/socks-template.json"
install -m 0644 "$REPO_DIR/logrotate.conf" /etc/logrotate.d/xray-dns
install -m 0644 "$REPO_DIR/systemd/xray-dns.service" /etc/systemd/system/xray-dns.service
install -m 0644 "$REPO_DIR/systemd/xray-dns.timer" /etc/systemd/system/xray-dns.timer
install -m 0644 "$REPO_DIR/systemd/xray-dns-rotator.service" /etc/systemd/system/xray-dns-rotator.service
install -m 0644 "$REPO_DIR/systemd/xray-dns-rotator.timer" /etc/systemd/system/xray-dns-rotator.timer
install -m 0644 "$REPO_DIR/systemd/xray-dns-bot.service" /etc/systemd/system/xray-dns-bot.service

ENV_FILE="$BASE_DIR/env"
if [[ ! -f "$ENV_FILE" ]]; then
    read -r -p "Hetzner DNS API Token: " HETZNER_DNS_API_TOKEN
    read -r -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    read -r -p "Telegram Allowed User ID: " TELEGRAM_ALLOWED_USER_ID
    read -r -p "Telegram Proxy (optional): " TELEGRAM_PROXY
    read -r -p "Monitor interval seconds (15/30) [15]: " MONITOR_INTERVAL
    MONITOR_INTERVAL=${MONITOR_INTERVAL:-15}
    read -r -p "Load balance interval seconds [60]: " LB_INTERVAL
    LB_INTERVAL=${LB_INTERVAL:-60}
    read -r -p "Fail threshold [3]: " FAIL_THRESHOLD
    FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}
    read -r -p "Success threshold [2]: " SUCCESS_THRESHOLD
    SUCCESS_THRESHOLD=${SUCCESS_THRESHOLD:-2}
    read -r -p "Default TTL [60]: " DEFAULT_TTL
    DEFAULT_TTL=${DEFAULT_TTL:-60}
    cat <<EOF_ENV > "$ENV_FILE"
HETZNER_DNS_API_TOKEN=$HETZNER_DNS_API_TOKEN
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_USER_ID=$TELEGRAM_ALLOWED_USER_ID
TELEGRAM_PROXY=$TELEGRAM_PROXY
MONITOR_INTERVAL=$MONITOR_INTERVAL
LB_INTERVAL=$LB_INTERVAL
FAIL_THRESHOLD=$FAIL_THRESHOLD
SUCCESS_THRESHOLD=$SUCCESS_THRESHOLD
DEFAULT_TTL=$DEFAULT_TTL
EOF_ENV
    chmod 600 "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

systemctl daemon-reload
systemctl enable --now xray-dns.timer
systemctl enable --now xray-dns-rotator.timer
systemctl enable --now xray-dns-bot.service

read -r -p "Managed domains (space separated, optional): " DOMAINS || true
if [[ -n "${DOMAINS:-}" ]]; then
    for domain in $DOMAINS; do
        /opt/xray-dns/xray-dns.sh --set-domain "$domain" || true
    done
fi

echo "Installation complete"
