#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helpers.sh"

LOG_FILE="$LOG_DIR/bot.log"
load_env
require_env TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID || exit 1

BOT_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
POLL_TIMEOUT=${POLL_TIMEOUT:-30}
OFFSET_FILE="$STATE_DIR/bot_offset"
SESSION_PREFIX="$STATE_DIR/bot_session_"
CLI="/opt/xray-dns/xray-dns.sh"

mkdir -p "$STATE_DIR"
[[ -f "$OFFSET_FILE" ]] || printf '0' > "$OFFSET_FILE"

telegram_curl() {
    local method=$1
    shift
    local url="${BOT_API}/${method}"
    local curl_args=(-sS --max-time 20)
    if [[ -n "${TELEGRAM_PROXY:-}" ]]; then
        curl_args+=(-x "$TELEGRAM_PROXY")
    fi
    curl "${curl_args[@]}" "$url" "$@"
}

send_message() {
    local chat_id=$1
    local text=$2
    local markup=${3:-}
    local payload
    if [[ -n "$markup" ]]; then
        payload=$(jq -n --arg chat_id "$chat_id" --arg text "$text" --argjson markup "$markup" '{chat_id:$chat_id,text:$text,reply_markup:$markup,parse_mode:"Markdown"}')
    else
        payload=$(jq -n --arg chat_id "$chat_id" --arg text "$text" '{chat_id:$chat_id,text:$text,parse_mode:"Markdown"}')
    fi
    telegram_curl sendMessage -H 'Content-Type: application/json' -d "$payload" >/dev/null
}

edit_message_markup() {
    local chat_id=$1
    local message_id=$2
    local markup=$3
    local payload
    payload=$(jq -n --arg chat_id "$chat_id" --argjson message_id "$message_id" --argjson markup "$markup" '{chat_id:$chat_id,message_id:$message_id,reply_markup:$markup}')
    telegram_curl editMessageReplyMarkup -H 'Content-Type: application/json' -d "$payload" >/dev/null || true
}

answer_callback() {
    local callback_id=$1
    local text=${2:-}
    local payload
    if [[ -n "$text" ]]; then
        payload=$(jq -n --arg callback_id "$callback_id" --arg text "$text" '{callback_query_id:$callback_id,text:$text,show_alert:false}')
    else
        payload=$(jq -n --arg callback_id "$callback_id" '{callback_query_id:$callback_id}')
    fi
    telegram_curl answerCallbackQuery -H 'Content-Type: application/json' -d "$payload" >/dev/null
}

main_keyboard() {
    jq -n '{inline_keyboard:[
        [{text:"وضعیت",callback_data:"status"}],
        [{text:"افزودن دامنه",callback_data:"add_domain"}],
        [{text:"افزودن کانفیگ",callback_data:"add_config"}],
        [{text:"مدیریت کانفیگ‌ها",callback_data:"manage_configs"}],
        [{text:"تغییر حالت",callback_data:"mode"}],
        [{text:"تغییر بازه‌ها",callback_data:"intervals"}],
        [{text:"تست فوری",callback_data:"test"}]
    ]}'
}

load_session() {
    local user_id=$1
    local file="${SESSION_PREFIX}${user_id}"
    if [[ -s "$file" ]]; then
        cat "$file"
    else
        printf '{}'
    fi
}

save_session() {
    local user_id=$1
    local step=$2
    local data=$3
    local file="${SESSION_PREFIX}${user_id}"
    jq -n --arg step "$step" --argjson data "$data" '{step:$step,data:$data}' > "$file"
}

clear_session() {
    local user_id=$1
    rm -f "${SESSION_PREFIX}${user_id}" >/dev/null 2>&1 || true
}

update_env_var() {
    local key=$1
    local value=$2
    local file="$ENV_FILE"
    touch "$file"
    chmod 600 "$file"
    if grep -q "^${key}=" "$file"; then
        sed -i "s#^${key}=.*#${key}=${value}#" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

run_cli() {
    local output
    if ! output=$("$CLI" "$@" 2>&1); then
        printf 'ERR:%s' "$output"
        return 1
    fi
    printf '%s' "$output"
}

send_status() {
    local chat_id=$1
    local output
    output=$(run_cli --status || true)
    send_message "$chat_id" "\`\`\`\n${output}\n\`\`\`"
}

handle_add_domain() {
    local user_id=$1
    save_session "$user_id" "await_domain" '{}'
}

complete_add_domain() {
    local chat_id=$1
    local domain=$2
    local result
    result=$(run_cli --set-domain "$domain" 2>&1 || true)
    send_message "$chat_id" "${result}"
}

handle_add_config() {
    local user_id=$1
    save_session "$user_id" "cfg_label" '{}'
}

session_step() {
    jq -r '.step // empty'
}

session_data() {
    jq -c '.data // {}'
}

handle_manage_configs() {
    local chat_id=$1
    local rows=()
    if compgen -G "$CONFIG_DIR"/*.json > /dev/null; then
        local file
        for file in "$CONFIG_DIR"/*.json; do
            [[ -f "$file" ]] || continue
            local info
            info=$(jq -c '{id,label,enabled}' "$file")
            local row
            row=$(jq -n --argjson info "$info" '[{text:($info.label + " (" + ($info.enabled|tostring) + ")"),callback_data:("toggle:"+$info.id)},{text:"❌",callback_data:("remove:"+$info.id)}]')
            rows+=("$row")
        done
    fi
    local keyboard='{"inline_keyboard":[]}'
    if (( ${#rows[@]} > 0 )); then
        keyboard=$(jq -n --slurpfile rows <(printf '%s\n' "${rows[@]}") '{inline_keyboard:$rows}')
    fi
    send_message "$chat_id" "لیست کانفیگ‌ها" "$keyboard"
}

handle_mode_menu() {
    local chat_id=$1
    local markup
    markup=$(jq -n '{inline_keyboard:[[{text:"Best",callback_data:"mode:best"},{text:"Round Robin",callback_data:"mode:rr"}]]}')
    send_message "$chat_id" "حالت را انتخاب کن" "$markup"
}

handle_intervals_menu() {
    local chat_id=$1
    local markup
    markup=$(jq -n '{inline_keyboard:[[{text:"پایش ۱۵ث",callback_data:"mon:15"},{text:"پایش ۳۰ث",callback_data:"mon:30"}],[{text:"گردش ۶۰ث",callback_data:"lb:60"},{text:"گردش 120ث",callback_data:"lb:120"}]]}')
    send_message "$chat_id" "بازه‌ها" "$markup"
}

trigger_test() {
    local chat_id=$1
    local output
    output=$(run_cli --monitor-once 2>&1 || true)
    send_message "$chat_id" "\`\`\`\n${output}\n\`\`\`"
}

process_session_message() {
    local chat_id=$1
    local user_id=$2
    local text=$3
    local session_json
    session_json=$(load_session "$user_id")
    local step
    step=$(session_step <<<"$session_json")
    local data
    data=$(session_data <<<"$session_json")
    case "$step" in
        await_domain)
            clear_session "$user_id"
            complete_add_domain "$chat_id" "$text"
            ;;
        cfg_label)
            data=$(jq -n --arg label "$text" '{label:$label}')
            save_session "$user_id" "cfg_ip" "$data"
            send_message "$chat_id" "IP را وارد کن"
            ;;
        cfg_ip)
            data=$(jq -n --argjson data "$data" --arg ip "$text" '$data + {ip:$ip}')
            save_session "$user_id" "cfg_json" "$data"
            send_message "$chat_id" "کانفیگ JSON را ارسال کن"
            ;;
       cfg_json)
           local clean
           clean=$(printf '%s' "$text" | sed 's/^```//;s/```$//')
           if ! jq empty <<<"$clean" >/dev/null 2>&1; then
               send_message "$chat_id" "JSON نامعتبر است. دوباره ارسال کن"
               return
           fi
           local label ip
           label=$(jq -r '.label' <<<"$data")
           ip=$(jq -r '.ip' <<<"$data")
            local result
            if result=$(XRAY_CONFIG_LABEL="$label" XRAY_CONFIG_IP="$ip" XRAY_CONFIG_JSON="$clean" "$CLI" --add-config 2>&1); then
                send_message "$chat_id" "کانفیگ ثبت شد"
            else
                send_message "$chat_id" "خطا: ${result}"
            fi
            clear_session "$user_id"
            ;;
        *)
            send_message "$chat_id" "برای شروع /start"
            ;;
    esac
}

handle_callback() {
    local update=$1
    local callback_id chat_id user_id data message_id
    callback_id=$(jq -r '.callback_query.id' <<<"$update")
    chat_id=$(jq -r '.callback_query.message.chat.id' <<<"$update")
    user_id=$(jq -r '.callback_query.from.id' <<<"$update")
    data=$(jq -r '.callback_query.data' <<<"$update")
    message_id=$(jq -r '.callback_query.message.message_id' <<<"$update")
    if [[ "$user_id" != "$TELEGRAM_ALLOWED_USER_ID" ]]; then
        answer_callback "$callback_id" "Unauthorized"
        return
    fi
    case "$data" in
        status)
            answer_callback "$callback_id"
            send_status "$chat_id"
            ;;
        add_domain)
            answer_callback "$callback_id" "نام دامنه؟"
            send_message "$chat_id" "نام دامنه را ارسال کن"
            handle_add_domain "$user_id"
            ;;
        add_config)
            answer_callback "$callback_id"
            send_message "$chat_id" "برچسب کانفیگ؟"
            handle_add_config "$user_id"
            ;;
        manage_configs)
            answer_callback "$callback_id"
            handle_manage_configs "$chat_id"
            ;;
        mode)
            answer_callback "$callback_id"
            handle_mode_menu "$chat_id"
            ;;
        intervals)
            answer_callback "$callback_id"
            handle_intervals_menu "$chat_id"
            ;;
        test)
            answer_callback "$callback_id" "درحال تست"
            trigger_test "$chat_id"
            ;;
        mode:*)
            answer_callback "$callback_id" "تغییر حالت"
            local mode=${data#mode:}
            "$CLI" --set-mode "$mode" >/tmp/bot_mode.log 2>&1 || true
            send_message "$chat_id" "حالت روی ${mode} تنظیم شد"
            ;;
        mon:*)
            answer_callback "$callback_id" "تنظیم شد"
            local value=${data#mon:}
            update_env_var MONITOR_INTERVAL "$value"
            send_message "$chat_id" "بازه پایش ${value}s"
            ;;
        lb:*)
            answer_callback "$callback_id" "تنظیم شد"
            local value=${data#lb:}
            update_env_var LB_INTERVAL "$value"
            send_message "$chat_id" "بازه گردشی ${value}s"
            ;;
        toggle:*)
            answer_callback "$callback_id"
            local id=${data#toggle:}
            local status
            status=$(jq -r '.enabled' "$CONFIG_DIR/$id.json" 2>/dev/null || echo "false")
            if [[ "$status" == "true" ]]; then
                local result
                if result=$("$CLI" --disable-config "$id" 2>&1); then
                    send_message "$chat_id" "غیرفعال شد"
                else
                    send_message "$chat_id" "خطا: ${result}"
                fi
            else
                local result
                if result=$("$CLI" --enable-config "$id" 2>&1); then
                    send_message "$chat_id" "فعال شد"
                else
                    send_message "$chat_id" "خطا: ${result}"
                fi
            fi
            ;;
        remove:*)
            answer_callback "$callback_id"
            local id=${data#remove:}
            local result
            if result=$("$CLI" --remove-config "$id" 2>&1); then
                send_message "$chat_id" "کانفیگ حذف شد"
            else
                send_message "$chat_id" "خطا: ${result}"
            fi
            ;;
        *)
            answer_callback "$callback_id" "نامشخص"
            ;;
    esac
}

handle_message() {
    local update=$1
    local chat_id user_id text
    chat_id=$(jq -r '.message.chat.id' <<<"$update")
    user_id=$(jq -r '.message.from.id' <<<"$update")
    text=$(jq -r '.message.text // ""' <<<"$update")
    if [[ "$user_id" != "$TELEGRAM_ALLOWED_USER_ID" ]]; then
        send_message "$chat_id" "دسترسی نداری"
        return
    fi
    case "$text" in
        /start|/menu)
            send_message "$chat_id" "خوش آمدی" "$(main_keyboard)"
            ;;
        *)
            process_session_message "$chat_id" "$user_id" "$text"
            ;;
    esac
}

process_updates() {
    local offset
    offset=$(cat "$OFFSET_FILE")
    local response
    response=$(telegram_curl getUpdates -d "offset=$offset&timeout=$POLL_TIMEOUT" || true)
    local ok
    ok=$(jq -r '.ok' <<<"$response" 2>/dev/null || echo "false")
    if [[ "$ok" != "true" ]]; then
        log_error "Telegram error: $response"
        sleep 5
        return
    fi
    jq -c '.result[]' <<<"$response" | while read -r update; do
        local update_id
        update_id=$(jq -r '.update_id' <<<"$update")
        echo $((update_id + 1)) > "$OFFSET_FILE"
        if jq -e '.message' <<<"$update" >/dev/null; then
            handle_message "$update"
        elif jq -e '.callback_query' <<<"$update" >/dev/null; then
            handle_callback "$update"
        fi
    done
}

main_loop() {
    while true; do
        with_lock bot process_updates
        sleep 1
    done
}

main_loop
