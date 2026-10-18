#!/usr/bin/env bash
# ==============================================================================
# TeamSpeak 3 Enterprise Watchdog & Auto-Healing Daemon
# Keeps TeamSpeak 3 alive 24/7/365 with multi-layer health checks & self-healing
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/manager.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
elif [[ -f "/opt/teamspeak/config/manager.conf" ]]; then
    # shellcheck source=/dev/null
    source "/opt/teamspeak/config/manager.conf"
fi

TS_USER="${TS_USER:-teamspeak}"
PORT_VOICE="${PORT_VOICE:-9987}"
PORT_QUERY="${PORT_QUERY:-10011}"
WATCHDOG_LOG="${WATCHDOG_LOG:-/var/log/ts3-watchdog.log}"
MAX_MEMORY_PERCENT="${MAX_MEMORY_PERCENT:-85}"
MAX_CPU_PERCENT="${MAX_CPU_PERCENT:-90}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/notify.sh" 2>/dev/null || true

# State file for anti-thrashing cooldown
COOLDOWN_FILE="/tmp/ts3_watchdog_cooldown"

log_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $msg" >> "$WATCHDOG_LOG" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg"
}

# Check Anti-Thrashing / Restart-loop protection
check_cooldown() {
    local now
    now=$(date +%s)
    if [[ -f "$COOLDOWN_FILE" ]]; then
        local count=0
        local last_restart=0
        read -r count last_restart < "$COOLDOWN_FILE" || true
        # If restarted more than 5 times within 300 seconds (5 min)
        if (( count >= 5 )) && (( now - last_restart < 300 )); then
            log_event "CRITICAL" "Crash-loop detected! TeamSpeak restarted 5 times in 5 minutes. Halting automatic recovery to prevent system freeze."
            if declare -F send_notification >/dev/null; then
                send_notification "Crash-Loop Alert!" "TeamSpeak has crashed repeatedly (5 times in 5 mins). Automatic recovery paused. Manual intervention required!" "ERROR"
            fi
            exit 1
        elif (( now - last_restart >= 300 )); then
            # Reset cooldown after 5 mins
            echo "1 $now" > "$COOLDOWN_FILE"
        else
            count=$((count + 1))
            echo "$count $now" > "$COOLDOWN_FILE"
        fi
    else
        echo "1 $now" > "$COOLDOWN_FILE"
    fi
}

# 1. Systemd Status Check
check_systemd_status() {
    if ! systemctl is-active --quiet teamspeak.service; then
        return 1
    fi
    return 0
}

# 2. Process Existence Check
check_process_exists() {
    local pid
    pid=$(pgrep -u "$TS_USER" -x "ts3server" || true)
    if [[ -z "$pid" ]]; then
        return 1
    fi
    return 0
}

# 3. Port & Socket Check (UDP Voice & TCP Query)
check_listening_sockets() {
    # Check UDP voice port (9987)
    if command -v ss >/dev/null 2>&1; then
        if ! ss -lunp | grep -q ":${PORT_VOICE} "; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if ! netstat -lunp 2>/dev/null | grep -q ":${PORT_VOICE} "; then
            return 1
        fi
    fi
    return 0
}

# 4. Resource Usage Check (Memory & CPU)
check_resource_usage() {
    local pid
    pid=$(pgrep -u "$TS_USER" -x "ts3server" || true)
    if [[ -n "$pid" ]]; then
        local mem_usage
        mem_usage=$(ps -p "$pid" -o %mem= | tr -d ' ' | cut -d'.' -f1 || echo "0")
        local cpu_usage
        cpu_usage=$(ps -p "$pid" -o %cpu= | tr -d ' ' | cut -d'.' -f1 || echo "0")

        if [[ -n "$mem_usage" ]] && (( mem_usage > MAX_MEMORY_PERCENT )); then
            log_event "WARNING" "High Memory Usage detected for PID $pid: ${mem_usage}% (Limit: ${MAX_MEMORY_PERCENT}%)"
            return 2 # Memory warning
        fi

        if [[ -n "$cpu_usage" ]] && (( cpu_usage > MAX_CPU_PERCENT )); then
            log_event "WARNING" "High CPU Usage detected for PID $pid: ${cpu_usage}% (Limit: ${MAX_CPU_PERCENT}%)"
            return 3 # CPU warning
        fi
    fi
    return 0
}

# Heal and Restart Service
heal_service() {
    local reason="$1"
    log_event "HEAL" "Initiating recovery procedure. Reason: ${reason}"
    check_cooldown

    if declare -F send_notification >/dev/null; then
        send_notification "Service Down - Healing" "TeamSpeak server issue detected (${reason}). Watchdog is reviving the server..." "WARNING"
    fi

    # Kill any stale or frozen ts3server processes if systemd is hung
    local stale_pids
    stale_pids=$(pgrep -u "$TS_USER" -x "ts3server" || true)
    if [[ -n "$stale_pids" ]] && ! check_systemd_status; then
        log_event "WARN" "Terminating orphaned ts3server process(es): $stale_pids"
        kill -9 $stale_pids 2>/dev/null || true
    fi

    # Restart systemd unit
    systemctl restart teamspeak.service

    # Wait for startup
    sleep 3

    if check_systemd_status && check_process_exists; then
        log_event "SUCCESS" "TeamSpeak 3 revived and verified healthy."
        if declare -F send_notification >/dev/null; then
            send_notification "Server Revived" "TeamSpeak 3 has been automatically restored and is running normally." "SUCCESS"
        fi
    else
        log_event "ERROR" "Failed to revive TeamSpeak 3! Immediate investigation required."
        if declare -F send_notification >/dev/null; then
            send_notification "Recovery Failed" "Watchdog attempted to restart TeamSpeak 3 but it failed to become active." "ERROR"
        fi
        exit 1
    fi
}

# Main Execution Flow
main() {
    # Check 1: Systemd service state
    if ! check_systemd_status; then
        heal_service "Systemd service 'teamspeak.service' is not active"
        exit 0
    fi

    # Check 2: Actual process check
    if ! check_process_exists; then
        heal_service "Binary 'ts3server' is not running under user '${TS_USER}'"
        exit 0
    fi

    # Check 3: Network sockets
    if ! check_listening_sockets; then
        heal_service "Voice port ${PORT_VOICE}/UDP is not actively listening"
        exit 0
    fi

    # Check 4: Resource limits
    local res_check=0
    check_resource_usage || res_check=$?
    if [[ $res_check -eq 2 ]]; then
        heal_service "Process exceeded memory threshold (${MAX_MEMORY_PERCENT}%)"
        exit 0
    elif [[ $res_check -eq 3 ]]; then
        # For CPU, wait 5 seconds and re-check before restarting
        sleep 5
        local res_check_re=0
        check_resource_usage || res_check_re=$?
        if [[ $res_check_re -eq 3 ]]; then
            heal_service "Process CPU pegged above threshold (${MAX_CPU_PERCENT}%) persistently"
            exit 0
        fi
    fi

    # All checks passed
    # Clean cooldown if running happily
    if [[ -f "$COOLDOWN_FILE" ]]; then
        local now
        now=$(date +%s)
        local count=0
        local last_restart=0
        read -r count last_restart < "$COOLDOWN_FILE" || true
        if (( now - last_restart > 3600 )); then
            rm -f "$COOLDOWN_FILE"
        fi
    fi
}

main "$@"
