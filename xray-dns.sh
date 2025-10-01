#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helpers.sh"

LOG_FILE="$LOG_DIR/xray-dns.log"
HEALTH_FILE="$STATE_DIR/health.json"
MODE_FILE="$STATE_DIR/mode"
DOMAINS_FILE="$STATE_DIR/domains.json"
RR_INDEX_FILE="$STATE_DIR/rr_index"
ALERT_FILE="$STATE_DIR/last_alert"
CURRENT_IP_FILE="$STATE_DIR/current_ip"

load_env

MONITOR_INTERVAL="${MONITOR_INTERVAL:-15}"
LB_INTERVAL="${LB_INTERVAL:-60}"
FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}
SUCCESS_THRESHOLD=${SUCCESS_THRESHOLD:-2}
MONITOR_URLS=("https://www.google.com/generate_204" "https://connectivitycheck.gstatic.com/generate_204")
CURL_TIMEOUT=${CURL_TIMEOUT:-5}
CURL_RETRIES=${CURL_RETRIES:-2}
DNS_MIN_UPDATE_INTERVAL=${DNS_MIN_UPDATE_INTERVAL:-10}
ALERT_COOLDOWN=${ALERT_COOLDOWN:-300}
DEFAULT_TTL=${DEFAULT_TTL:-60}

usage() {
    cat <<USAGE
Usage: $0 [options]
Options:
  --monitor-once          Run one monitor iteration (best latency)
  --rotate-once           Run one round-robin rotation
  --set-mode MODE         Set mode to 'best' or 'rr'
  --list                  List configured endpoints
  --add-config            Add new Xray config from stdin or prompts
  --remove-config ID      Remove config by ID
  --enable-config ID      Enable config by ID
  --disable-config ID     Disable config by ID
  --set-domain DOMAIN     Add or set domain for management
  --status                Show system status summary
  --self-check            Run self check diagnostics
  -h, --help              Show this help
USAGE
}

ensure_state_files() {
    mkdir -p "$STATE_DIR" "$CONFIG_DIR"
    if [[ ! -f "$HEALTH_FILE" ]]; then
        printf '{}\n' > "$HEALTH_FILE"
    fi
    if [[ ! -f "$MODE_FILE" ]]; then
        printf 'best' > "$MODE_FILE"
    fi
    if [[ ! -f "$DOMAINS_FILE" ]]; then
        printf '{"domains":{}}' > "$DOMAINS_FILE"
    fi
}

list_configs() {
    ensure_state_files
    for file in "$CONFIG_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        local data
        data=$(cat "$file")
        local id label ip enabled
        id=$(jq -r '.id' <<<"$data")
        label=$(jq -r '.label' <<<"$data")
        ip=$(jq -r '.ip' <<<"$data")
        enabled=$(jq -r '.enabled' <<<"$data")
        local health
        health=$(jq -r --arg id "$id" '.[$id]' "$HEALTH_FILE" 2>/dev/null || printf 'null')
        printf 'ID: %s\nLabel: %s\nIP: %s\nEnabled: %s\nHealth: %s\n---\n' "$id" "$label" "$ip" "$enabled" "$health"
    done
}

generate_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        date +%s%N
    fi
}

add_config() {
    ensure_state_files
    local id label ip config_json temp config_file
    id=$(generate_id)
    if [[ -n "${XRAY_CONFIG_LABEL:-}" ]]; then
        label=$XRAY_CONFIG_LABEL
    else
        read -r -p "Label: " label
    fi
    if [[ -n "${XRAY_CONFIG_IP:-}" ]]; then
        ip=$XRAY_CONFIG_IP
    else
        read -r -p "IP: " ip
    fi
    if [[ -n "${XRAY_CONFIG_JSON:-}" ]]; then
        temp=$(mktemp)
        printf '%s' "$XRAY_CONFIG_JSON" > "$temp"
    elif [[ -n "${XRAY_CONFIG_JSON_FILE:-}" ]]; then
        temp=$XRAY_CONFIG_JSON_FILE
    else
        printf 'Enter config JSON (end with EOF):\n' >&2
        temp=$(mktemp)
        cat > "$temp"
    fi
    if ! jq empty "$temp" >/dev/null 2>&1; then
        log_error "Invalid JSON"
        [[ "$temp" != "$XRAY_CONFIG_JSON_FILE" ]] && rm -f "$temp"
        return 1
    fi
    local target="$CONFIG_DIR/$id.json"
    jq -n --arg id "$id" --arg label "$label" --arg ip "$ip" --slurpfile cfg "$temp" '{id:$id,label:$label,ip:$ip,enabled:true,config_json:$cfg[0]}' > "$target"
    [[ "$temp" != "$XRAY_CONFIG_JSON_FILE" ]] && rm -f "$temp"
    log_info "Added config $id"
}

remove_config() {
    local id=$1
    local file="$CONFIG_DIR/$id.json"
    if [[ -f "$file" ]]; then
        rm -f "$file"
        log_info "Removed config $id"
        jq "del(.\"$id\")" "$HEALTH_FILE" > "$HEALTH_FILE.tmp" && mv "$HEALTH_FILE.tmp" "$HEALTH_FILE"
    else
        log_warn "Config $id not found"
    fi
}

set_config_enabled() {
    local id=$1
    local enabled=$2
    local file="$CONFIG_DIR/$id.json"
    if [[ ! -f "$file" ]]; then
        log_warn "Config $id not found"
        return 1
    fi
    jq --argjson enabled "$enabled" '.enabled=$enabled' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log_info "Config $id enabled=$enabled"
}

set_mode() {
    local mode=$1
    if [[ "$mode" != "best" && "$mode" != "rr" ]]; then
        log_error "Invalid mode $mode"
        return 1
    fi
    printf '%s' "$mode" > "$MODE_FILE"
    log_info "Mode set to $mode"
}

add_domain() {
    local domain=$1
    ensure_state_files
    local domains_json
    domains_json=$(cat "$DOMAINS_FILE")
    if jq -e --arg domain "$domain" '.domains[$domain]' <<<"$domains_json" >/dev/null 2>&1; then
        log_info "Domain $domain already tracked"
        return 0
    fi
    local zone_id record_id
    zone_id=$(hetzner_find_zone "$domain") || return 1
    record_id=$(hetzner_ensure_record "$zone_id" "$domain") || return 1
    jq --arg domain "$domain" --arg zone "$zone_id" --arg record "$record_id" '.domains[$domain]={"zone_id":$zone,"record_id":$record,"last_ip":null,"last_update":null}' <<<"$domains_json" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
    log_info "Domain $domain added"
}

get_domains() {
    jq -r '.domains | keys[]' "$DOMAINS_FILE"
}

hetzner_request() {
    require_env HETZNER_DNS_API_TOKEN || return 1
    local method=$1
    local path=$2
    shift 2
    local url="https://dns.hetzner.com/api/v1${path}"
    http_request "$method" "$url" -H "Authorization: Bearer $HETZNER_DNS_API_TOKEN" -H 'Content-Type: application/json' "$@"
}

hetzner_find_zone() {
    local domain=$1
    local response
    response=$(hetzner_request GET '/zones?per_page=200') || {
        log_error "Failed to fetch zones"
        return 1
    }
    local zone_name zone_id best_match_len=0
    while IFS= read -r zone; do
        zone_name=$(jq -r '.name' <<<"$zone")
        if [[ "$domain" == *"$zone_name" ]]; then
            local len=${#zone_name}
            if (( len > best_match_len )); then
                best_match_len=$len
                zone_id=$(jq -r '.id' <<<"$zone")
            fi
        fi
    done < <(jq -c '.zones[]' <<<"$response")
    if [[ -z "${zone_id:-}" ]]; then
        log_error "Zone for $domain not found"
        return 1
    fi
    printf '%s' "$zone_id"
}

hetzner_ensure_record() {
    local zone_id=$1
    local domain=$2
    local response
    response=$(hetzner_request GET "/records?zone_id=$zone_id&per_page=200") || return 1
    local record_id
    record_id=$(jq -r --arg name "$domain" '.records[] | select(.name==$name and .type=="A") | .id' <<<"$response" | head -n1)
    if [[ -n "$record_id" ]]; then
        printf '%s' "$record_id"
        return 0
    fi
    local name="$domain"
    local body
    body=$(jq -n --arg zone "$zone_id" --arg name "$name" --arg ttl "$DEFAULT_TTL" '{zone_id:$zone,type:"A",name:$name,value:"0.0.0.0",ttl:($ttl|tonumber)}')
    response=$(hetzner_request POST '/records' -d "$body") || return 1
    record_id=$(jq -r '.record.id' <<<"$response")
    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        log_error "Failed to create record for $domain"
        return 1
    fi
    printf '%s' "$record_id"
}

hetzner_update_record() {
    local domain=$1
    local ip=$2
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local domains_json
    domains_json=$(cat "$DOMAINS_FILE")
    local zone_id record_id last_ip last_update
    zone_id=$(jq -r --arg domain "$domain" '.domains[$domain].zone_id' <<<"$domains_json")
    record_id=$(jq -r --arg domain "$domain" '.domains[$domain].record_id' <<<"$domains_json")
    last_ip=$(jq -r --arg domain "$domain" '.domains[$domain].last_ip' <<<"$domains_json")
    last_update=$(jq -r --arg domain "$domain" '.domains[$domain].last_update' <<<"$domains_json")
    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        log_error "Domain $domain not initialised"
        return 1
    fi
    local now_epoch last_epoch
    now_epoch=$(date -d "$now" +%s)
    if [[ -n "$last_update" && "$last_update" != "null" ]]; then
        last_epoch=$(date -d "$last_update" +%s)
        if (( now_epoch - last_epoch < DNS_MIN_UPDATE_INTERVAL )); then
            log_info "Skipping update for $domain due to rate limit"
            return 0
        fi
    fi
    if [[ "$last_ip" == "$ip" ]]; then
        log_info "IP unchanged for $domain"
        return 0
    fi
    local body
    body=$(jq -n --arg id "$record_id" --arg name "$domain" --arg value "$ip" --arg ttl "$DEFAULT_TTL" '{id:$id,type:"A",name:$name,value:$value,ttl:($ttl|tonumber)}')
    hetzner_request PUT "/records/$record_id" -d "$body" >/dev/null || {
        log_error "Failed to update record for $domain"
        return 1
    }
    jq --arg domain "$domain" --arg ip "$ip" --arg ts "$now" '.domains[$domain].last_ip=$ip | .domains[$domain].last_update=$ts' <<<"$domains_json" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
    printf '%s' "$ip" > "$CURRENT_IP_FILE"
    log_info "Updated $domain to $ip"
}

choose_best_config() {
    local health_json=$1
    jq -r 'to_entries | map(select(.value.healthy == true and (.value.last_latency_ms != null))) | sort_by(.value.last_latency_ms) | .[0].value.ip' <<<"$health_json" 2>/dev/null
}

healthy_configs_list() {
    local health_json=$1
    jq -r 'to_entries | map(select(.value.healthy == true)) | map(.value.ip) | unique | .[]' <<<"$health_json"
}

send_alert() {
    local message=$1
    local now_epoch
    now_epoch=$(date +%s)
    local last=0
    if [[ -f "$ALERT_FILE" ]]; then
        last=$(cat "$ALERT_FILE")
    fi
    if (( now_epoch - last < ALERT_COOLDOWN )); then
        log_info "Skipping alert (rate limited)"
        return
    fi
    printf '%s' "$now_epoch" > "$ALERT_FILE"
    log_warn "$message"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]]; then
        local payload
        payload=$(jq -n --arg chat_id "$TELEGRAM_ALLOWED_USER_ID" --arg text "$message" '{chat_id:$chat_id,text:$text,disable_notification:false}')
        if [[ -n "${TELEGRAM_PROXY:-}" ]]; then
            curl -sS --max-time 10 -x "$TELEGRAM_PROXY" -H 'Content-Type: application/json' -d "$payload" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null || true
        else
            curl -sS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null || true
        fi
    fi
}

run_tests_for_config() {
    local config_file=$1
    local target_url
    local config_data
    config_data=$(cat "$config_file")
    local id label ip
    id=$(jq -r '.id' <<<"$config_data")
    label=$(jq -r '.label' <<<"$config_data")
    ip=$(jq -r '.ip' <<<"$config_data")
    local enabled
    enabled=$(jq -r '.enabled' <<<"$config_data")
    if [[ "$enabled" != "true" ]]; then
        jq -n --arg id "$id" --arg label "$label" --arg ip "$ip" '{id:$id,label:$label,ip:$ip,skip:true}'
        return
    fi
    local outbound
    outbound=$(jq -c '.config_json' <<<"$config_data")
    local port temp_config
    port=$(shuf -i 20000-60000 -n1)
    temp_config=$(mktemp)
    local template
    template=$(cat "$TEMPLATE_DIR/socks-template.json")
    template=${template//{{PORT}}/$port}
    template=${template//{{OUTBOUND}}/$outbound}
    printf '%s' "$template" > "$temp_config"
    local log_file
    log_file=$(mktemp)
    local pid
    if ! command -v xray >/dev/null 2>&1; then
        log_error "xray binary not found"
        jq -n --arg id "$id" --arg label "$label" --arg ip "$ip" '{id:$id,label:$label,ip:$ip,success:false,error:"xray-not-found",latency_ms:null}'
        rm -f "$temp_config" "$log_file"
        return
    fi
    xray run -config "$temp_config" >"$log_file" 2>&1 &
    pid=$!
    sleep 1
    local attempt=1
    local best_latency=999999
    local success_count=0
    local error_msg=""
    while (( attempt <= CURL_RETRIES )); do
        for target_url in "${MONITOR_URLS[@]}"; do
            local output curl_exit
            output=$(curl -sS --max-time "$CURL_TIMEOUT" --socks5-hostname "127.0.0.1:$port" -o /dev/null -w '%{time_total}' "$target_url" 2>&1)
            curl_exit=$?
            if [[ $curl_exit -eq 0 && "$output" =~ ^[0-9.]+$ ]]; then
                local latency_ms
                latency_ms=$(awk -v t="$output" 'BEGIN{printf "%.0f", t*1000}')
                if (( latency_ms < best_latency )); then
                    best_latency=$latency_ms
                fi
                success_count=$((success_count+1))
            else
                error_msg="$output"
            fi
        done
        ((attempt++))
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$temp_config" "$log_file"
    if (( success_count > 0 )); then
        jq -n --arg id "$id" --arg label "$label" --arg ip "$ip" --argjson latency "$best_latency" '{id:$id,label:$label,ip:$ip,success:true,error:null,latency_ms:$latency}'
    else
        jq -n --arg id "$id" --arg label "$label" --arg ip "$ip" --arg error "$error_msg" '{id:$id,label:$label,ip:$ip,success:false,error:$error,latency_ms:null}'
    fi
}

update_health_state() {
    local results_json=$1
    local health_json
    health_json=$(cat "$HEALTH_FILE")
    local updated
    updated=$(jq --argjson res "$results_json" --argjson success_threshold "$SUCCESS_THRESHOLD" --argjson fail_threshold "$FAIL_THRESHOLD" '
      reduce ($res[] | select(.skip != true)) as $r (.;
        $id := $r.id;
        $existing := (.[$id] // {
            id: $id,
            label: $r.label,
            ip: $r.ip,
            healthy: false,
            last_latency_ms: null,
            last_error: null,
            last_ok: null,
            last_checked: null,
            ok_streak: 0,
            fail_streak: 0
        });
        if $r.success then
            .[$id] = ($existing
                | .label = $r.label
                | .ip = $r.ip
                | .last_latency_ms = $r.latency_ms
                | .last_checked = $r.timestamp
                | .last_ok = $r.timestamp
                | .last_error = null
                | .fail_streak = 0
                | .ok_streak = ($existing.ok_streak + 1)
                | .healthy = ($existing.healthy or (($existing.ok_streak + 1) >= $r.success_threshold))
            )
        else
            .[$id] = ($existing
                | .label = $r.label
                | .ip = $r.ip
                | .last_checked = $r.timestamp
                | .last_error = $r.error
                | .last_latency_ms = null
                | .ok_streak = 0
                | .fail_streak = ($existing.fail_streak + 1)
                | .healthy = (if ($existing.fail_streak + 1) >= $r.fail_threshold then false else $existing.healthy end)
            )
        end
      )
    ' <<<"$health_json")
    printf '%s' "$updated" > "$HEALTH_FILE"
    printf '%s' "$updated"
}

monitor_once() {
    ensure_state_files
    local now_epoch
    now_epoch=$(date +%s)
    local last_file="$STATE_DIR/last_monitor"
    if [[ -f "$last_file" ]]; then
        local last_epoch
        last_epoch=$(cat "$last_file")
        if (( now_epoch - last_epoch < MONITOR_INTERVAL )); then
            log_info "Skipping monitor run due to interval"
            return 0
        fi
    fi
    require_env HETZNER_DNS_API_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID || true
    local configs=()
    for file in "$CONFIG_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        configs+=("$file")
    done
    if (( ${#configs[@]} == 0 )); then
        log_warn "No configs available"
        return 0
    fi
    local results=()
    local tmp
    tmp=$(mktemp)
    local idx=0
    for file in "${configs[@]}"; do
        (
            local res timestamp
            timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            res=$(run_tests_for_config "$file")
            jq --arg ts "$timestamp" --argjson success_threshold "$SUCCESS_THRESHOLD" --argjson fail_threshold "$FAIL_THRESHOLD" '. + {timestamp:$ts,success_threshold:$success_threshold,fail_threshold:$fail_threshold}' <<<"$res"
        ) > "$tmp.$idx" &
        idx=$((idx+1))
    done
    wait
    local json_array='[]'
    for f in "$tmp".*; do
        [[ -f "$f" ]] || continue
        json_array=$(jq --slurpfile item "$f" '. + $item' <<<"$json_array")
        rm -f "$f"
    done
    rm -f "$tmp"
    local updated_health
    updated_health=$(update_health_state "$json_array")
    local mode
    mode=$(cat "$MODE_FILE")
    if [[ "$mode" != "best" ]]; then
        printf '%s' "$now_epoch" > "$last_file"
        log_info "Monitor executed in mode $mode (no DNS change)"
        return 0
    fi
    local best_ip
    best_ip=$(choose_best_config "$updated_health")
    if [[ -z "$best_ip" || "$best_ip" == "null" ]]; then
        send_alert "هیچ کانفیگ سالمی موجود نیست"
        printf '%s' "$now_epoch" > "$last_file"
        return 1
    fi
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        hetzner_update_record "$domain" "$best_ip"
    done < <(get_domains)
    printf '%s' "$now_epoch" > "$last_file"
}

rotate_once() {
    ensure_state_files
    local now_epoch
    now_epoch=$(date +%s)
    local last_file="$STATE_DIR/last_rotate"
    if [[ -f "$last_file" ]]; then
        local last_epoch
        last_epoch=$(cat "$last_file")
        if (( now_epoch - last_epoch < LB_INTERVAL )); then
            log_info "Skipping rotate run due to interval"
            return 0
        fi
    fi
    local health_json
    health_json=$(cat "$HEALTH_FILE")
    local ips
    ips=($(healthy_configs_list "$health_json"))
    if (( ${#ips[@]} == 0 )); then
        send_alert "هیچ IP سالمی برای گردشی نیست"
        printf '%s' "$now_epoch" > "$last_file"
        return 1
    fi
    local index=0
    if [[ -f "$RR_INDEX_FILE" ]]; then
        index=$(cat "$RR_INDEX_FILE")
    fi
    local selected_ip
    selected_ip="${ips[$((index % ${#ips[@]}))]}"
    printf '%s' $(( (index + 1) % ${#ips[@]} )) > "$RR_INDEX_FILE"
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        hetzner_update_record "$domain" "$selected_ip"
    done < <(get_domains)
    log_info "Round robin selected $selected_ip"
    printf '%s' "$now_epoch" > "$last_file"
}

status_report() {
    ensure_state_files
    local mode
    mode=$(cat "$MODE_FILE")
    local current_ip=""
    [[ -f "$CURRENT_IP_FILE" ]] && current_ip=$(cat "$CURRENT_IP_FILE")
    printf 'Mode: %s\n' "$mode"
    printf 'Current IP: %s\n' "${current_ip:-unknown}"
    printf 'Domains:\n'
    jq -r '.domains | to_entries[] | " - \(.key): last_ip=\(.value.last_ip) updated=\(.value.last_update)"' "$DOMAINS_FILE"
    printf 'Configs:\n'
    list_configs
}

self_check() {
    ensure_state_files
    local ok=true
    for cmd in curl jq xray systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Missing dependency: $cmd"
            ok=false
        fi
    done
    if [[ ! -f "$ENV_FILE" ]]; then
        log_warn "Env file missing at $ENV_FILE"
        ok=false
    fi
    if [[ "$ok" == true ]]; then
        log_info "Self-check passed"
    else
        log_warn "Self-check encountered issues"
    fi
}

main() {
    ensure_state_files
    if (($# == 0)); then
        usage
        exit 1
    fi
    case "$1" in
        --monitor-once)
            with_lock monitor "monitor_once"
            ;;
        --rotate-once)
            with_lock rotate "rotate_once"
            ;;
        --set-mode)
            shift
            set_mode "$1"
            ;;
        --list)
            list_configs
            ;;
        --add-config)
            add_config
            ;;
        --remove-config)
            shift
            remove_config "$1"
            ;;
        --enable-config)
            shift
            set_config_enabled "$1" true
            ;;
        --disable-config)
            shift
            set_config_enabled "$1" false
            ;;
        --set-domain)
            shift
            add_domain "$1"
            ;;
        --status)
            status_report
            ;;
        --self-check)
            self_check
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
