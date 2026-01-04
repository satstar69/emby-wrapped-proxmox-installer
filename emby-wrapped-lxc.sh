#!/usr/bin/env bash

# Emby Wrapped LXC Installation Script
# License: MIT
# Interactive installation only

function header_info() {
  clear
  cat <<"EOF"
    ______           __             _       __                                      __
   / ____/___ ___   / /_    __  __ | |     / /_____ ____ _ ____   ____   ___   ____/ /
  / __/  / __ `__ \ / __ \ / / / / | | /| / // ___// __ `// __ \ / __ \ / _ \ / __  / 
 / /___ / / / / / // /_/ // /_/ /  | |/ |/ // /   / /_/ // /_/ // /_/ //  __// /_/ /  
/_____//_/ /_/ /_//_.___/ \__, /   |__/|__//_/    \__,_// .___// .___/ \___/ \__,_/   
                         /____/                        /_/    /_/                      
                         
            Spotify Wrapped-Style Year in Review for Emby
EOF
}

set -eEuo pipefail

# Safety checks
if ! command -v pct &> /dev/null; then
    echo "ERROR: This script must be run on a Proxmox VE host!"
    exit 1
fi

if systemd-detect-virt -c &> /dev/null; then
    echo "ERROR: This script cannot be run inside a container!"
    exit 1
fi

YW="\033[33m"
BL="\033[36m"
RD="\033[01;31m"
BGN="\033[4;92m"
GN="\033[1;92m"
DGN="\033[32m"
CL="\033[m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
HOLD="-"

# Functions
msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${HOLD} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${HOLD} ${CROSS} ${RD}${msg}${CL}"
}

# Get next available CT ID
get_next_ctid() {
  NEXT_ID=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].vmid' 2>/dev/null | sort -n | tail -1)
  if [ -z "$NEXT_ID" ]; then
    echo "100"
  else
    echo $((NEXT_ID + 1))
  fi
}

# Check if CT exists
check_ctid_exists() {
  if pct status "$1" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Get storage list
get_storage_list() {
  pvesm status -content rootdir | awk 'NR>1 {print $1}'
}

# Fixed HTTP Port
HTTP_PORT=3000

# Main installation
header_info
echo ""

if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "Emby Wrapped LXC Installer" --yesno "This will install Emby Wrapped in a new LXC container.\n\nRequires: Emby server with Playback Reporting plugin\n\nProceed?" 12 65; then
  echo -e "${RD}Installation cancelled${CL}"
  exit 0
fi

# Get Container ID
SUGGESTED_CTID=$(get_next_ctid)
CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter Container ID" 8 58 "$SUGGESTED_CTID" --title "Container ID" 3>&1 1>&2 2>&3)

exitstatus=$?
if [ $exitstatus != 0 ]; then
  echo -e "${RD}Installation cancelled${CL}"
  exit 1
fi

if check_ctid_exists "$CTID"; then
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Error" --msgbox "Container $CTID already exists!" 8 50
  exit 1
fi

# Get Hostname
HOSTNAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter hostname" 8 58 "emby-wrapped" --title "Hostname" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Get Password
PASSWORD=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Enter root password" 8 58 --title "Password" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

PASSWORD_CONFIRM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Confirm root password" 8 58 --title "Confirm Password" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Error" --msgbox "Passwords don't match!" 8 50
  exit 1
fi

# Get Storage
STORAGE_LIST=()
while read -r line; do
  STORAGE_LIST+=("$line" "")
done < <(get_storage_list)

if [ ${#STORAGE_LIST[@]} -eq 0 ]; then
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Error" --msgbox "No suitable storage found for containers!" 8 60
  exit 1
fi

STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage" --menu "\nSelect storage:" 16 58 6 "${STORAGE_LIST[@]}" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Get Disk Size
DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter disk size (GB)" 8 58 "4" --title "Disk Size" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Get CPU Cores
CORES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter number of CPU cores" 8 58 "1" --title "CPU Cores" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Get Memory
MEMORY=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter RAM (MB)" 8 58 "1024" --title "Memory" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Get Swap
SWAP=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter SWAP (MB)" 8 58 "512" --title "Swap" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Get Bridge
BRIDGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter network bridge" 8 58 "vmbr0" --title "Network Bridge" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# IP Configuration
IP_TYPE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Network Configuration" --menu "\nSelect IP configuration:" 12 58 2 \
  "1" "DHCP" \
  "2" "Static IP" 3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then exit 1; fi

if [ "$IP_TYPE" = "2" ]; then
  STATIC_IP=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter static IP (e.g., 192.168.1.100/24)" 8 58 --title "Static IP" 3>&1 1>&2 2>&3)
  if [ $? -ne 0 ]; then exit 1; fi
  
  GATEWAY=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter gateway" 8 58 --title "Gateway" 3>&1 1>&2 2>&3)
  if [ $? -ne 0 ]; then exit 1; fi
  
  NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=$STATIC_IP,gw=$GATEWAY"
else
  NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp"
fi

# Get Emby Configuration
EMBY_URL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter Emby Server URL\n(e.g., http://192.168.1.50:8096)" 10 65 --title "Emby Server URL" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

EMBY_API_KEY=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter Emby API Key\n(Dashboard > Advanced > API Keys)" 10 65 --title "Emby API Key" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

# Optional TMDB API Key
if whiptail --backtitle "Proxmox VE Helper Scripts" --title "TMDB Integration" --yesno "Do you want to configure TMDB API key?\n(For enhanced movie/show posters)" 10 60; then
  TMDB_API_KEY=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter TMDB API Key\n(Get from: https://www.themoviedb.org/settings/api)" 10 65 --title "TMDB API Key (Optional)" 3>&1 1>&2 2>&3)
  if [ $? -ne 0 ]; then
    TMDB_API_KEY=""
  fi
else
  TMDB_API_KEY=""
fi

# Get Template
TEMPLATE_UBUNTU=$(pveam list local 2>/dev/null | grep -E "ubuntu-(25\.04|24\.04)" | head -1 | awk '{print $1}')

if [ -z "$TEMPLATE_UBUNTU" ]; then
  header_info
  msg_info "Downloading Ubuntu template"
  
  UBUNTU_TEMPLATE=$(pveam available 2>/dev/null | grep ubuntu-25.04 | grep standard | head -1 | awk '{print $2}')
  
  if [ -z "$UBUNTU_TEMPLATE" ]; then
    UBUNTU_TEMPLATE=$(pveam available 2>/dev/null | grep ubuntu-24.04 | grep standard | head -1 | awk '{print $2}')
  fi
  
  if [ -z "$UBUNTU_TEMPLATE" ]; then
    msg_error "Could not find Ubuntu template"
    exit 1
  fi
  
  pveam download local "$UBUNTU_TEMPLATE" >/dev/null 2>&1
  TEMPLATE="local:vztmpl/$UBUNTU_TEMPLATE"
  msg_ok "Template downloaded"
else
  TEMPLATE="$TEMPLATE_UBUNTU"
fi

# Start on boot
if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Auto-start" --yesno "Start container on boot?" 8 58; then
  ONBOOT_FLAG=1
else
  ONBOOT_FLAG=0
fi

# Confirmation
SUMMARY="Container ID: $CTID\nHostname: $HOSTNAME\nStorage: $STORAGE\nDisk: ${DISK_SIZE}GB\nCPU: $CORES cores\nRAM: ${MEMORY}MB\nSwap: ${SWAP}MB\nNetwork: $NET_CONFIG\nHTTP Port: 3000\n\nEmby Server: $EMBY_URL"

if [ -n "$TMDB_API_KEY" ]; then
  SUMMARY="$SUMMARY\nTMDB: Configured"
fi

if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "Confirm Installation" --yesno "$SUMMARY\n\nProceed with installation?" 20 70; then
  echo -e "${RD}Installation cancelled${CL}"
  exit 1
fi

# Create container
header_info
msg_info "Creating LXC container"

pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK_SIZE" \
  --net0 "$NET_CONFIG" \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --onboot "$ONBOOT_FLAG" >/dev/null 2>&1

msg_ok "Container created"

msg_info "Starting container"
pct start "$CTID"
sleep 5
msg_ok "Container started"

# Create installation script
cat >/tmp/emby-wrapped-install.sh <<INSTALL_EOF
#!/bin/bash
set -e

YW="\033[33m"
BL="\033[36m"
GN="\033[1;92m"
CL="\033[m"
CM="\${GN}✓\${CL}"

echo -e "\n\${GN}Installing Emby Wrapped...\${CL}\n"

# Update system
echo -ne " - \${YW}Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1
apt-get upgrade -y >/dev/null 2>&1
echo -e " \${CM}"

# Install dependencies
echo -ne " - \${YW}Installing dependencies..."
apt-get install -y curl wget git ca-certificates gnupg figlet >/dev/null 2>&1
echo -e " \${CM}"

# Install Docker
echo -ne " - \${YW}Installing Docker..."
curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
systemctl enable docker >/dev/null 2>&1
systemctl start docker
echo -e " \${CM}"

# Create docker-compose file
echo -ne " - \${YW}Creating Docker Compose configuration..."
mkdir -p /opt/emby-wrapped

cat > /opt/emby-wrapped/docker-compose.yml <<'DOCKER_EOF'
version: '3.8'

services:
  emby-wrapped:
    image: ghcr.io/davidtorcivia/emby-wrapped-ftp:latest
    container_name: emby-wrapped
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - EMBY_URL=$EMBY_URL
      - EMBY_API_KEY=$EMBY_API_KEY
DOCKER_EOF

# Add TMDB if configured
if [ -n "$TMDB_API_KEY" ]; then
  cat >> /opt/emby-wrapped/docker-compose.yml <<DOCKER_EOF
      - TMDB_API_KEY=$TMDB_API_KEY
DOCKER_EOF
fi

# Close the docker-compose file
echo "" >> /opt/emby-wrapped/docker-compose.yml

echo -e " \${CM}"

# Start container
echo -ne " - \${YW}Starting Emby Wrapped container..."
cd /opt/emby-wrapped
docker compose up -d >/dev/null 2>&1
echo -e " \${CM}"

# Configure MOTD
echo -ne " - \${YW}Configuring MOTD..."
chmod -x /etc/update-motd.d/* 2>/dev/null || true

cat > /etc/update-motd.d/00-emby-wrapped-header <<'MOTD_EOF'
#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

HOSTNAME=\$(hostname)
IP_ADDRESS=\$(hostname -I | awk '{print \$1}')

clear
echo ""
echo -e "\${GREEN}"
figlet -f standard "Emby Wrapped"
echo -e "\${NC}"
echo -e "\${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "\${GREEN}  Container:\${NC} \${HOSTNAME}"
echo -e "\${GREEN}  IP Address:\${NC} \${IP_ADDRESS}"
echo -e "\${GREEN}  Web Interface:\${NC} \${YELLOW}http://\${IP_ADDRESS}:3000\${NC}"
echo -e "\${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo ""
echo -e "\${CYAN}🎬 Spotify Wrapped-Style Year in Review for Emby\${NC}"
echo ""
echo -e "  • Personalized year-in-review stats"
echo -e "  • Top movies, shows, and genres"
echo -e "  • Watch time analytics"
echo -e "  • Shareable results"
echo ""
echo -e "\${YELLOW}Quick Commands:\${NC}"
echo -e "  \${GREEN}update\${NC}             Update Emby Wrapped to latest version"
echo -e "  \${GREEN}wrapped-logs\${NC}       View container logs"
echo -e "  \${GREEN}wrapped-status\${NC}     Check container status"
echo -e "  \${GREEN}wrapped-restart\${NC}    Restart container"
echo ""
MOTD_EOF

chmod +x /etc/update-motd.d/00-emby-wrapped-header

cat > /etc/profile.d/emby-wrapped-motd.sh <<'PROFILE_EOF'
if [ -f /etc/update-motd.d/00-emby-wrapped-header ]; then
    /etc/update-motd.d/00-emby-wrapped-header
fi
PROFILE_EOF

chmod +x /etc/profile.d/emby-wrapped-motd.sh
echo -e " \${CM}"

# Create update command
echo -ne " - \${YW}Creating update command..."
cat > /usr/local/bin/emby-wrapped-update <<'UPDATE_CMD'
#!/bin/bash

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "\${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "\${GREEN}  Emby Wrapped Update\${NC}"
echo -e "\${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo ""

if [ ! -f "/opt/emby-wrapped/docker-compose.yml" ]; then
    echo -e "\${RED}Error: Emby Wrapped not found in /opt/emby-wrapped\${NC}"
    exit 1
fi

cd /opt/emby-wrapped

# Get current image ID
echo -ne "Checking current version... "
CURRENT_IMAGE=\$(docker images ghcr.io/davidtorcivia/emby-wrapped-ftp --format "{{.ID}}" | head -1)
echo -e "\${GREEN}✓\${NC}"

# Pull latest image
echo -ne "Pulling latest image... "
docker compose pull >/dev/null 2>&1
echo -e "\${GREEN}✓\${NC}"

# Get new image ID
NEW_IMAGE=\$(docker images ghcr.io/davidtorcivia/emby-wrapped-ftp --format "{{.ID}}" | head -1)

if [ "\${CURRENT_IMAGE}" != "\${NEW_IMAGE}" ]; then
    echo -e "\${GREEN}New version available\${NC}"
    
    # Restart container
    echo -ne "Restarting container... "
    docker compose down >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
    echo -e "\${GREEN}✓\${NC}"
    
    # Remove old image
    if [ -n "\${CURRENT_IMAGE}" ]; then
        echo -ne "Cleaning up old images... "
        docker image rm \${CURRENT_IMAGE} >/dev/null 2>&1 || true
        echo -e "\${GREEN}✓\${NC}"
    fi
else
    echo -e "\${GREEN}Already up to date\${NC}"
fi

echo ""
echo -e "\${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "\${GREEN}Update complete!\${NC}"
echo -e "\${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo ""

IP_ADDRESS=\$(hostname -I | awk '{print \$1}')
echo -e "Access Emby Wrapped at: \${YELLOW}http://\${IP_ADDRESS}:3000\${NC}"
echo ""
UPDATE_CMD

chmod +x /usr/local/bin/emby-wrapped-update

# Create convenient aliases
cat >> /root/.bashrc <<'ALIAS_EOF'

# Emby Wrapped shortcuts
alias update='emby-wrapped-update'
alias wrapped-logs='docker logs -f emby-wrapped'
alias wrapped-status='docker ps -a | grep emby-wrapped'
alias wrapped-restart='cd /opt/emby-wrapped && docker compose restart'
ALIAS_EOF

echo -e " \${CM}"

CONTAINER_IP=\$(hostname -I | awk '{print \$1}')
echo -e "\n\${GN}Installation complete!\${CL}"
echo -e "\${BL}Access at: \${YW}http://\${CONTAINER_IP}:3000\${CL}\n"
INSTALL_EOF

# Execute installation
msg_info "Installing Emby Wrapped (this may take several minutes)"
pct push "$CTID" /tmp/emby-wrapped-install.sh /root/install.sh
pct exec "$CTID" -- bash -c "export EMBY_URL='$EMBY_URL' EMBY_API_KEY='$EMBY_API_KEY' TMDB_API_KEY='$TMDB_API_KEY' && bash /root/install.sh"
rm -f /tmp/emby-wrapped-install.sh
msg_ok "Installation complete"

# Get container IP
CONTAINER_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

# Final message
header_info
echo -e "${GN}Emby Wrapped successfully installed!${CL}\n"
echo -e "${BL}Container ID:${CL} $CTID"
echo -e "${BL}Hostname:${CL} $HOSTNAME"
echo -e "${BL}IP Address:${CL} $CONTAINER_IP"
echo -e "\n${YW}Access Emby Wrapped at:${CL} ${BGN}http://$CONTAINER_IP:3000${CL}\n"
echo -e "${GN}MOTD banner configured - connection info shown on login${CL}\n"
echo -e "${DGN}Quick Commands (inside container):${CL}"
echo -e "  ${BL}update${CL}             Update Emby Wrapped to latest version"
echo -e "  ${BL}wrapped-logs${CL}       View container logs"
echo -e "  ${BL}wrapped-status${CL}     Check container status"
echo -e "  ${BL}wrapped-restart${CL}    Restart container"
echo -e "\n${DGN}Enter container:${CL} ${BL}pct enter $CTID${CL}\n"
echo -e "${YW}Note:${CL} Emby server must have the Playback Reporting plugin installed!"
echo -e "${YW}Dashboard > Plugins > Catalog > Playback Reporting${CL}\n"
