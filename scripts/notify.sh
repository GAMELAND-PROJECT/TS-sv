#!/usr/bin/env bash
# ==============================================================================
# TeamSpeak 3 Manager - Notification Engine (Discord & Telegram)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/manager.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
elif [[ -f "/opt/teamspeak/config/manager.conf" ]]; then
    # shellcheck source=/dev/null
    source "/opt/teamspeak/config/manager.conf"
fi

# Function: Send Discord Notification
# Arguments: $1 = Title, $2 = Message, $3 = Level (SUCCESS|INFO|WARNING|ERROR)
send_discord() {
    local title="$1"
    local message="$2"
    local level="${3:-INFO}"

    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
        return 0
    fi

    local color=3447003 # Blue (INFO)
    local status_emoji="ℹ️"

    case "$level" in
        SUCCESS)
            color=3066993 # Green
            status_emoji="✅"
            ;;
        WARNING)
            color=15844367 # Yellow/Gold
            status_emoji="⚠️"
            ;;
        ERROR)
            color=15158332 # Red
            status_emoji="🚨"
            ;;
    esac

    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local payload
    payload=$(jq -n \
        --arg title "${status_emoji} ${title}" \
        --arg desc "${message}" \
        --argjson col "$color" \
        --arg host "${hostname}" \
        --arg time "$timestamp" \
        '{
            embeds: [{
                title: $title,
                description: $desc,
                color: $col,
                fields: [
                    { name: "Server Host", value: $host, inline: true },
                    { name: "Service", value: "TeamSpeak 3", inline: true }
                ],
                footer: { text: "TS3 Enterprise Watchdog" },
                timestamp: $time
            }]
        }')

    curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1 || true
}

# Function: Send Telegram Notification
# Arguments: $1 = Title, $2 = Message, $3 = Level (SUCCESS|INFO|WARNING|ERROR)
send_telegram() {
    local title="$1"
    local message="$2"
    local level="${3:-INFO}"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        return 0
    fi

    local status_emoji="ℹ️"
    case "$level" in
        SUCCESS) status_emoji="✅" ;;
        WARNING) status_emoji="⚠️" ;;
        ERROR)   status_emoji="🚨" ;;
    esac

    local hostname
    hostname=$(hostname)

    local text="<b>${status_emoji} ${title}</b>%0A"
    text+="<b>Host:</b> <code>${hostname}</code>%0A"
    text+="<b>Status:</b> ${level}%0A%0A"
    text+="${message}"

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${text}" \
        -d "parse_mode=HTML" > /dev/null 2>&1 || true
}

# Main Dispatcher
# Usage: ./notify.sh "Title" "Message Body" "SUCCESS|INFO|WARNING|ERROR"
send_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-INFO}"

    send_discord "$title" "$message" "$level"
    send_telegram "$title" "$message" "$level"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -ge 2 ]]; then
        send_notification "$1" "$2" "${3:-INFO}"
    else
        echo "Usage: $0 <title> <message> [SUCCESS|INFO|WARNING|ERROR]"
    fi
fi
