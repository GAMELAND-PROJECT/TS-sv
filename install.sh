#!/usr/bin/env bash
# ==============================================================================
# TeamSpeak 3 Enterprise Server Automated Installer for Ubuntu Linux
# Zero-Touch Deployment with Auto-Healing, Firewall & Systemd Hardening
# ==============================================================================
set -euo pipefail

# ANSI Styling
BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
WHITE="\033[1;37m"
GRAY="\033[0;90m"
NC="\033[0m"

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/teamspeak"
TS_USER="teamspeak"
TS_GROUP="teamspeak"

log_info() { echo -e "${CYAN}[*]${NC} $1"; }
log_step() { echo -e "\n${BLUE}${BOLD}==>${NC} ${WHITE}${BOLD}$1${NC}"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This installer must be run as root (or with sudo)!"
    echo -e "Please re-run: ${BOLD}sudo bash install.sh${NC}"
    exit 1
fi

clear 2>/dev/null || true
echo -e "${CYAN}${BOLD}"
cat << "EOF"
  _______ _____ ____    _____                            
 |__   __/ ____|___ \  / ____|                           
    | | | (___   __) || |     ___  _ __ ___  _ __   __ _ 
    | |  \___ \ |__ < | |    / _ \| '_ ` _ \| '_ \ / _` |
    | |  ____) |___) || |___| (_) | | | | | | |_) | (_| |
    |_| |_____/|____/  \_____\___/|_| |_| |_| .__/ \__,_|
                                            | |          
   Enterprise High-Availability Controller  |_|   Installer
EOF
echo -e "${NC}${GRAY}────────────────────────────────────────────────────────────────────────${NC}"
echo -e "${WHITE}Preparing to deploy TeamSpeak 3 Server on Ubuntu Linux...${NC}\n"

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    log_error "Unsupported architecture: $ARCH. TeamSpeak 3 Server requires x86_64 (amd64)."
    exit 1
fi

log_step "Step 1/8: Installing System Dependencies (curl, bzip2, tar, jq, sqlite3, ufw)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget bzip2 tar net-tools jq sqlite3 ufw cron procps >/dev/null
log_success "Prerequisites installed successfully."

log_step "Step 2/8: Configuring Dedicated System User (${TS_USER})..."
if id "$TS_USER" >/dev/null 2>&1; then
    log_info "User '${TS_USER}' already exists."
else
    useradd -r -s /usr/sbin/nologin -d "$TARGET_DIR" -c "TeamSpeak 3 Server Daemon" "$TS_USER"
    log_success "Created isolated system user: ${TS_USER}"
fi

log_step "Step 3/8: Resolving & Downloading Latest TeamSpeak 3 Server Release..."
LATEST_VER=$(curl -s https://files.teamspeak-services.com/releases/server/ | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/"' | tr -d 'href="/' | sort -V | tail -n1 || true)
if [[ -z "$LATEST_VER" ]]; then
    LATEST_VER="3.13.7"
fi
log_info "Target Version: ${LATEST_VER}"

DOWNLOAD_URL="https://files.teamspeak-services.com/releases/server/${LATEST_VER}/teamspeak3-server_linux_amd64-${LATEST_VER}.tar.bz2"
TMP_DIR=$(mktemp -d /tmp/ts3_install_XXXXXX)
TARBALL="${TMP_DIR}/ts3server.tar.bz2"

log_info "Downloading from CDN: ${DOWNLOAD_URL} ..."
curl -f -L -o "$TARBALL" "$DOWNLOAD_URL"
log_success "Download complete."

log_step "Step 4/8: Extracting Files to ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"
tar -xjf "$TARBALL" -C "$TMP_DIR"
cp -rn "${TMP_DIR}/teamspeak3-server_linux_amd64/"* "$TARGET_DIR/"
echo "$LATEST_VER" > "${TARGET_DIR}/version.txt"
rm -rf "$TMP_DIR"

touch "${TARGET_DIR}/.ts3server_license_accepted"

mkdir -p "${TARGET_DIR}/config" "${TARGET_DIR}/scripts" "${TARGET_DIR}/backups" "${TARGET_DIR}/logs"
cp -f "${INSTALLER_DIR}/config/ts3server.ini" "${TARGET_DIR}/ts3server.ini"
cp -f "${INSTALLER_DIR}/config/manager.conf" "${TARGET_DIR}/config/manager.conf"
cp -rf "${INSTALLER_DIR}/scripts/"* "${TARGET_DIR}/scripts/"
chmod +x "${TARGET_DIR}/scripts/"*.sh
chmod +x "${TARGET_DIR}/ts3server"
chmod +x "${TARGET_DIR}/ts3server_startscript.sh"

cp -f "${INSTALLER_DIR}/ts3ctl" /usr/local/bin/ts3ctl
cp -f "${INSTALLER_DIR}/ts3ctl" "${TARGET_DIR}/ts3ctl"
chmod +x /usr/local/bin/ts3ctl
chmod +x "${TARGET_DIR}/ts3ctl"

chown -R "${TS_USER}:${TS_GROUP}" "$TARGET_DIR"
log_success "Files deployed with proper security permissions."

log_step "Step 5/8: Registering Systemd Services & Watchdog Timer..."
cp -f "${INSTALLER_DIR}/systemd/teamspeak.service" /etc/systemd/system/teamspeak.service
cp -f "${INSTALLER_DIR}/systemd/ts3-watchdog.service" /etc/systemd/system/ts3-watchdog.service
cp -f "${INSTALLER_DIR}/systemd/ts3-watchdog.timer" /etc/systemd/system/ts3-watchdog.timer

systemctl daemon-reload
systemctl enable teamspeak.service >/dev/null 2>&1
systemctl enable ts3-watchdog.timer >/dev/null 2>&1
log_success "Systemd units enabled on boot."

log_step "Step 6/8: Configuring Firewall (UFW)..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 9987/udp comment 'TeamSpeak 3 Voice' >/dev/null 2>&1 || true
    ufw allow 30033/tcp comment 'TeamSpeak 3 File Transfer' >/dev/null 2>&1 || true
    ufw allow 10011/tcp comment 'TeamSpeak 3 ServerQuery' >/dev/null 2>&1 || true
    ufw allow 10022/tcp comment 'TeamSpeak 3 SSH Query' >/dev/null 2>&1 || true
    log_success "TeamSpeak ports (9987 UDP, 30033 TCP, 10011 TCP, 10022 TCP) allowed in UFW."
fi

log_step "Step 7/8: Scheduling Daily Automated Backups..."
CRON_JOB="0 4 * * * /opt/teamspeak/scripts/backup.sh create >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "backup.sh"; echo "$CRON_JOB") | crontab -
log_success "Daily backup scheduled at 04:00 AM."

log_step "Step 8/8: Starting TeamSpeak 3 Server & Capturing Admin Credentials..."
systemctl start teamspeak.service
systemctl start ts3-watchdog.timer

log_info "Waiting 5 seconds for database initialization..."
sleep 5

SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
TOKEN=$(journalctl -u teamspeak.service --no-pager 2>/dev/null | grep -oE 'token=[a-zA-Z0-9+/=]+' | tail -n1 || true)
if [[ -z "$TOKEN" && -d "${TARGET_DIR}/logs" ]]; then
    TOKEN=$(grep -oE 'token=[a-zA-Z0-9+/=]+' "${TARGET_DIR}/logs/"* 2>/dev/null | tail -n1 || true)
fi

echo ""
echo -e "${GREEN}${BOLD}========================================================================${NC}"
echo -e "${GREEN}${BOLD}           🎉 TEAMSPEAK 3 ENTERPRISE SERVER READY!                     ${NC}"
echo -e "${GREEN}${BOLD}========================================================================${NC}"
echo -e "  ${WHITE}${BOLD}Server IP / Address:${NC}  ${CYAN}${BOLD}${SERVER_IP}:9987${NC}"
echo -e "  ${WHITE}${BOLD}Status:${NC}                ${GREEN}${BOLD}ACTIVE & WATCHDOG PROTECTED${NC}"
echo -e "  ${WHITE}${BOLD}Voice Port:${NC}            ${CYAN}9987 (UDP)${NC}"
echo -e "  ${WHITE}${BOLD}File Transfer Port:${NC}    ${CYAN}30033 (TCP)${NC}"
echo -e "  ${WHITE}${BOLD}ServerQuery Port:${NC}      ${CYAN}10011 (TCP)${NC}"
echo -e "  ${WHITE}${BOLD}Installation Path:${NC}     ${WHITE}${TARGET_DIR}${NC}"
echo ""
if [[ -n "$TOKEN" ]]; then
    echo -e "${YELLOW}${BOLD}  ServerAdmin Privilege Key (Token):${NC}"
    echo -e "  ${WHITE}${BOLD}${TOKEN}${NC}"
    echo -e "  ${GRAY}(Connect via your TS3 client, click 'Permissions' -> 'Use Privilege Key' and paste this)${NC}"
else
    echo -e "${YELLOW}  Note: If token is not visible yet, run: ${WHITE}${BOLD}ts3ctl token${NC}"
fi
echo -e "${GREEN}────────────────────────────────────────────────────────────────────────${NC}"
echo -e "${WHITE}${BOLD}Control Commands:${NC}"
echo -e "  ${CYAN}ts3ctl${NC}             -> Open Interactive Management Menu"
echo -e "  ${CYAN}ts3ctl status${NC}      -> View live health, memory, CPU & ports"
echo -e "  ${CYAN}ts3ctl backup${NC}      -> Create an instant hot backup"
echo -e "  ${CYAN}ts3ctl update${NC}      -> Update TeamSpeak to the newest version"
echo -e "  ${CYAN}ts3ctl logs${NC}        -> View real-time live logs"
echo -e "  ${CYAN}ts3ctl restart${NC}     -> Safe restart"
echo -e "${GREEN}========================================================================${NC}"
