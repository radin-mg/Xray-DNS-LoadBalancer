#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

BASE_DIR="/opt/xray-dns"
ENV_FILE="$BASE_DIR/env"
LOG_DIR="$BASE_DIR/logs"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$BASE_DIR/configs"
TEMPLATE_DIR="$BASE_DIR/templates"
LOCK_DIR="$STATE_DIR"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$CONFIG_DIR" "$TEMPLATE_DIR" >/dev/null 2>&1 || true

_log() {
    local level=$1
    shift
    local msg="$*"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local target_log="${LOG_FILE:-$LOG_DIR/xray-dns.log}"
    mkdir -p "$(dirname "$target_log")"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$target_log"
}

log_info() { _log "INFO" "$*"; }
log_warn() { _log "WARN" "$*"; }
log_error() { _log "ERROR" "$*"; }

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi
}

require_env() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required environment variables: ${missing[*]}"
        return 1
    fi
    return 0
}

with_lock() {
    local name=$1
    shift
    local lock_file="$LOCK_DIR/${name}.lock"
    mkdir -p "$LOCK_DIR"
    exec {lock_fd}>"$lock_file"
    if ! flock -n "$lock_fd"; then
        log_warn "Lock $name is already held"
        return 0
    fi
    "$@"
    local status=$?
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return $status
}

http_request() {
    local method=$1
    local url=$2
    shift 2
    local headers=()
    local data=""
    local timeout=15
    local retry=3
    local backoff=2
    while (($#)); do
        case "$1" in
            -H)
                headers+=("-H" "$2")
                shift 2
                ;;
            -d)
                data="$2"
                shift 2
                ;;
            -t)
                timeout=$2
                shift 2
                ;;
            -r)
                retry=$2
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    local attempt=1
    local resp
    while (( attempt <= retry )); do
        if [[ -n "$data" ]]; then
            resp=$(curl -sS --max-time "$timeout" -X "$method" "${headers[@]}" -d "$data" "$url" || true)
        else
            resp=$(curl -sS --max-time "$timeout" -X "$method" "${headers[@]}" "$url" || true)
        fi
        if [[ -n "$resp" ]]; then
            printf '%s' "$resp"
            return 0
        fi
        sleep $(( backoff ** attempt ))
        ((attempt++))
    done
    return 1
}

json_get() {
    local json=$1
    local query=$2
    jq -r "$query" <<<"$json"
}

load_state_json() {
    local file=$1
    if [[ -s "$file" ]]; then
        cat "$file"
    else
        printf '{}'
    fi
}

save_state_json() {
    local file=$1
    local json=$2
    printf '%s' "$json" > "$file"
}

