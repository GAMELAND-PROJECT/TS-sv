#!/usr/bin/env bash
# ==============================================================================
# TeamSpeak 3 Manager - Backup & Restore System
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
BACKUP_DIR="${BACKUP_DIR:-/opt/teamspeak/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TS_USER="${TS_USER:-teamspeak}"
TS_GROUP="${TS_GROUP:-teamspeak}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/notify.sh" 2>/dev/null || true

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

ensure_dirs() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        chown -R "${TS_USER}:${TS_GROUP}" "$BACKUP_DIR" 2>/dev/null || true
    fi
}

# Create Backup
create_backup() {
    ensure_dirs
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_name="ts3_backup_${timestamp}.tar.gz"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    local temp_backup_dir
    temp_backup_dir=$(mktemp -d /tmp/ts3_backup_XXXXXX)

    log_info "Initiating safe hot backup of TeamSpeak 3..."

    # Gather essential files: db, ini, whitelist/blacklist, files folder, licenses
    local items_to_backup=()
    [[ -f "${TS_DIR}/ts3server.sqlitedb" ]] && items_to_backup+=("ts3server.sqlitedb")
    [[ -f "${TS_DIR}/ts3server.ini" ]] && items_to_backup+=("ts3server.ini")
    [[ -d "${TS_DIR}/files" ]] && items_to_backup+=("files")
    [[ -f "${TS_DIR}/query_ip_whitelist.txt" ]] && items_to_backup+=("query_ip_whitelist.txt")
    [[ -f "${TS_DIR}/query_ip_blacklist.txt" ]] && items_to_backup+=("query_ip_blacklist.txt")
    [[ -d "${TS_DIR}/license" ]] && items_to_backup+=("license")
    [[ -f "${TS_DIR}/.ts3server_license_accepted" ]] && items_to_backup+=(".ts3server_license_accepted")
    [[ -d "${TS_DIR}/config" ]] && items_to_backup+=("config")

    if [[ ${#items_to_backup[@]} -eq 0 ]]; then
        log_error "No TeamSpeak data found to backup in ${TS_DIR}!"
        rm -rf "$temp_backup_dir"
        exit 1
    fi

    # SQLite Hot Copy (ensure consistent database copy)
    if [[ -f "${TS_DIR}/ts3server.sqlitedb" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "${TS_DIR}/ts3server.sqlitedb" ".backup '${temp_backup_dir}/ts3server.sqlitedb'"
        else
            cp -p "${TS_DIR}/ts3server.sqlitedb" "${temp_backup_dir}/ts3server.sqlitedb"
        fi
    fi

    # Copy other items to temp dir
    for item in "${items_to_backup[@]}"; do
        if [[ "$item" != "ts3server.sqlitedb" && -e "${TS_DIR}/${item}" ]]; then
            cp -rp "${TS_DIR}/${item}" "${temp_backup_dir}/"
        fi
    done

    # Add metadata
    cat <<EOF > "${temp_backup_dir}/backup_metadata.txt"
Created-At: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Host: $(hostname)
Source-Dir: ${TS_DIR}
Backup-Type: Hot Snapshot
EOF

    # Tar and compress
    tar -czf "$backup_path" -C "$temp_backup_dir" .
    rm -rf "$temp_backup_dir"

    # Generate checksum
    sha256sum "$backup_path" > "${backup_path}.sha256"
    chown "${TS_USER}:${TS_GROUP}" "$backup_path" "${backup_path}.sha256" 2>/dev/null || true

    local backup_size
    backup_size=$(du -h "$backup_path" | cut -f1)
    log_success "Backup completed successfully: ${backup_name} (${backup_size})"

    # Clean old backups
    clean_old_backups

    # Notify
    if declare -F send_notification >/dev/null; then
        send_notification "Backup Completed" "TeamSpeak 3 backup created: \`${backup_name}\` (Size: ${backup_size})" "SUCCESS"
    fi
}

# Clean old backups according to retention policy
clean_old_backups() {
    log_info "Enforcing retention policy (${BACKUP_RETENTION_DAYS} days)..."
    find "$BACKUP_DIR" -type f -name "ts3_backup_*.tar.gz" -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -f {} +
    find "$BACKUP_DIR" -type f -name "ts3_backup_*.tar.gz.sha256" -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -f {} +
    log_info "Retention cleanup done."
}

# List available backups
list_backups() {
    ensure_dirs
    echo -e "${CYAN}=== Available Backups in ${BACKUP_DIR} ===${NC}"
    local count=0
    for f in "${BACKUP_DIR}"/ts3_backup_*.tar.gz; do
        if [[ -f "$f" ]]; then
            count=$((count + 1))
            local size
            size=$(du -h "$f" | cut -f1)
            local mod
            mod=$(date -r "$f" +"%Y-%m-%d %H:%M:%S")
            echo -e "${GREEN}[$count]${NC} $(basename "$f")  |  Size: ${size}  |  Date: ${mod}"
        fi
    done

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}No backups found.${NC}"
    fi
}

# Restore from a backup archive
restore_backup() {
    local target_backup="${1:-}"

    if [[ -z "$target_backup" ]]; then
        log_error "Please specify a backup file to restore."
        list_backups
        exit 1
    fi

    if [[ ! -f "$target_backup" ]]; then
        if [[ -f "${BACKUP_DIR}/${target_backup}" ]]; then
            target_backup="${BACKUP_DIR}/${target_backup}"
        else
            log_error "Backup file not found: $target_backup"
            exit 1
        fi
    fi

    # Verify SHA256 if checksum exists
    if [[ -f "${target_backup}.sha256" ]]; then
        log_info "Verifying backup integrity with SHA256 checksum..."
        if ! sha256sum --check --status "${target_backup}.sha256"; then
            log_error "Integrity check FAILED! Corrupted backup archive."
            exit 1
        fi
        log_success "Integrity verified successfully."
    fi

    echo -e "${YELLOW}⚠️ WARNING: Restoring will overwrite existing TeamSpeak database and channel files!${NC}"
    read -rp "Are you sure you want to proceed? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Restore cancelled by user."
        exit 0
    fi

    log_info "Stopping TeamSpeak service before restoration..."
    systemctl stop teamspeak.service 2>/dev/null || true

    log_info "Restoring files to ${TS_DIR}..."
    tar -xzf "$target_backup" -C "$TS_DIR"

    log_info "Setting correct ownership (${TS_USER}:${TS_GROUP})..."
    chown -R "${TS_USER}:${TS_GROUP}" "$TS_DIR"

    log_info "Restarting TeamSpeak service..."
    systemctl start teamspeak.service

    sleep 2
    if systemctl is-active --quiet teamspeak.service; then
        log_success "Restoration successfully completed! TeamSpeak is UP and RUNNING."
        if declare -F send_notification >/dev/null; then
            send_notification "Restore Completed" "TeamSpeak server restored from \`$(basename "$target_backup")\`" "SUCCESS"
        fi
    else
        log_error "TeamSpeak failed to start after restoration! Check 'journalctl -u teamspeak.service'."
        if declare -F send_notification >/dev/null; then
            send_notification "Restore Failed" "TeamSpeak failed to start after restoring \`$(basename "$target_backup")\`" "ERROR"
        fi
        exit 1
    fi
}

# CLI Switch
case "${1:-create}" in
    create|backup)
        create_backup
        ;;
    list)
        list_backups
        ;;
    restore)
        shift
        restore_backup "${1:-}"
        ;;
    clean)
        clean_old_backups
        ;;
    *)
        echo "Usage: $0 {backup|list|restore <filename>|clean}"
        exit 1
        ;;
esac
