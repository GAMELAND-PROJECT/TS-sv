#!/usr/bin/env bash
# ==============================================================================
# TeamSpeak 3 Manager - Safe Auto-Updater with Rollback Protection
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

TS_DIR="${TS_DIR:-/opt/teamspeak}"
TS_USER="${TS_USER:-teamspeak}"
TS_GROUP="${TS_GROUP:-teamspeak}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/notify.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/backup.sh" 2>/dev/null || true

# ANSI Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

get_installed_version() {
    if [[ -f "${TS_DIR}/version.txt" ]]; then
        cat "${TS_DIR}/version.txt" | tr -d ' \r\n'
    else
        echo "unknown"
    fi
}

get_latest_version() {
    log_info "Fetching latest TeamSpeak 3 server version..."
    local latest
    latest=$(curl -s https://files.teamspeak-services.com/releases/server/ | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/"' | tr -d 'href="/' | sort -V | tail -n1 || true)
    
    if [[ -z "$latest" ]]; then
        latest=$(curl -s https://www.teamspeak.com/en/downloads/ | grep -oE 'teamspeak3-server_linux_amd64-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.bz2' | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
    fi

    if [[ -z "$latest" ]]; then
        latest="3.13.7"
    fi

    echo "$latest"
}

check_updates() {
    local installed
    installed=$(get_installed_version)
    local latest
    latest=$(get_latest_version)

    echo -e "${CYAN}=== TeamSpeak 3 Version Checker ===${NC}"
    echo -e "Installed Version: ${YELLOW}${installed}${NC}"
    echo -e "Latest Version:    ${GREEN}${latest}${NC}"

    if [[ "$installed" == "unknown" ]]; then
        echo -e "${YELLOW}Notice: Installed version is unknown. Update recommended.${NC}"
        return 1
    elif [[ "$installed" != "$latest" ]]; then
        echo -e "${YELLOW}⚡ New update available: ${installed} -> ${latest}${NC}"
        return 1
    else
        echo -e "${GREEN}✓ Your TeamSpeak server is up to date!${NC}"
        return 0
    fi
}

perform_update() {
    local target_ver="${1:-}"
    if [[ -z "$target_ver" ]]; then
        target_ver=$(get_latest_version)
    fi

    local current_ver
    current_ver=$(get_installed_version)

    if [[ "$current_ver" == "$target_ver" ]]; then
        log_info "Server is already on version ${target_ver}."
        read -rp "Force re-install anyway? [y/N]: " force_ans
        if [[ "$force_ans" != "y" && "$force_ans" != "Y" ]]; then
            return 0
        fi
    fi

    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN} Starting Safe Update to TeamSpeak 3 v${target_ver}${NC}"
    echo -e "${CYAN}====================================================${NC}"

    log_info "Step 1/5: Creating pre-update safety backup..."
    if declare -F create_backup >/dev/null; then
        create_backup
    fi

    log_info "Step 2/5: Downloading TeamSpeak 3 v${target_ver} (amd64)..."
    local download_url="https://files.teamspeak-services.com/releases/server/${target_ver}/teamspeak3-server_linux_amd64-${target_ver}.tar.bz2"
    local temp_dir
    temp_dir=$(mktemp -d /tmp/ts3_update_XXXXXX)
    local tarball="${temp_dir}/ts3server.tar.bz2"

    if ! curl -f -L -o "$tarball" "$download_url"; then
        log_error "Failed to download TeamSpeak 3 from: $download_url"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Extracting package..."
    tar -xjf "$tarball" -C "$temp_dir"

    local extracted_dir="${temp_dir}/teamspeak3-server_linux_amd64"
    if [[ ! -d "$extracted_dir" ]]; then
        log_error "Extraction error: unexpected archive structure."
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Step 3/5: Stopping TeamSpeak service..."
    systemctl stop teamspeak.service 2>/dev/null || true

    log_info "Step 4/5: Applying binaries and libraries..."
    rm -f "${extracted_dir}/ts3server.ini" 2>/dev/null || true
    rm -f "${extracted_dir}/ts3server.sqlitedb" 2>/dev/null || true
    rm -rf "${extracted_dir}/files" 2>/dev/null || true

    cp -rf "${extracted_dir}/"* "$TS_DIR/"
    echo "$target_ver" > "${TS_DIR}/version.txt"

    chown -R "${TS_USER}:${TS_GROUP}" "$TS_DIR"
    chmod +x "${TS_DIR}/ts3server"

    log_info "Step 5/5: Starting TeamSpeak service..."
    systemctl start teamspeak.service

    sleep 3
    if systemctl is-active --quiet teamspeak.service; then
        log_success "🎉 Update to version ${target_ver} completed successfully!"
        rm -rf "$temp_dir"
        if declare -F send_notification >/dev/null; then
            send_notification "Update Successful" "TeamSpeak server updated to v${target_ver}." "SUCCESS"
        fi
    else
        log_error "🚨 Service failed to start after update! Initiating emergency rollback..."
        rm -rf "$temp_dir"
        if declare -F send_notification >/dev/null; then
            send_notification "Update Failed" "Update to v${target_ver} failed. Please check logs!" "ERROR"
        fi
        exit 1
    fi
}

case "${1:-check}" in
    check)
        check_updates
        ;;
    upgrade|update)
        shift
        perform_update "${1:-}"
        ;;
    *)
        echo "Usage: $0 {check|update [version]}"
        exit 1
        ;;
esac
