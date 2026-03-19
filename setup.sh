#!/bin/bash
# =============================================================================
# Nebra Indoor Gen 1 → The Things Network Gateway Setup
# =============================================================================
# Repurposes a Nebra Indoor Hotspot Gen 1 (CM3 + GL5712-UX / SX1301) as a
# LoRa Basics Station gateway connected to The Things Network (US915 FSB2).
#
# Usage: sudo bash setup.sh
# =============================================================================

set -e

# ---- Colours ----------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

# ---- Require root -----------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash setup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/ttn-station"
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
ACTUAL_USER="${SUDO_USER:-$USER}"

# =============================================================================
# STEP 1 — Gather configuration interactively
# =============================================================================
header "TTN Gateway Configuration"

echo "This script will set up your Nebra Indoor Gen 1 as a TTN LoRa gateway."
echo "You will need:"
echo "  • A TTN account and registered gateway"
echo "  • Your gateway's API key (LNS key with traffic exchange right)"
echo ""

# Gateway EUI (auto-detect from eth0)
DETECTED_EUI=$(python3 -c "
import subprocess
mac = open('/sys/class/net/eth0/address').read().strip()
p = mac.split(':')
print((p[0]+p[1]+p[2]+'FFFE'+p[3]+p[4]+p[5]).upper())
" 2>/dev/null || echo "")

if [[ -n "$DETECTED_EUI" ]]; then
    echo -e "  Detected Gateway EUI: ${BOLD}${DETECTED_EUI}${NC}"
    echo "  Use this EUI when registering your gateway on TTN."
    echo ""
fi

# TTN API Key
while true; do
    read -rp "$(echo -e "${BOLD}Enter your TTN LNS API key${NC} (NNSXS.xxx...): ")" TTN_API_KEY
    if [[ "$TTN_API_KEY" =~ ^NNSXS\. ]]; then
        break
    else
        warn "Key should start with NNSXS. — try again."
    fi
done

# TTN Region / Cluster
echo ""
echo "TTN cluster options:"
echo "  1) nam1  — North America (US915) [default]"
echo "  2) eu1   — Europe (EU868)"
echo "  3) au1   — Australia (AU915)"
read -rp "Select cluster [1]: " CLUSTER_CHOICE
case "${CLUSTER_CHOICE:-1}" in
    2) TTN_CLUSTER="eu1" ;;
    3) TTN_CLUSTER="au1" ;;
    *) TTN_CLUSTER="nam1" ;;
esac

# Frequency plan
echo ""
echo "Frequency plan options:"
echo "  1) US915 FSB2 — United States (used by TTN) [default]"
echo "  2) EU868      — Europe"
echo "  3) AU915 FSB2 — Australia"
read -rp "Select frequency plan [1]: " FREQ_CHOICE
case "${FREQ_CHOICE:-1}" in
    2) FREQ_PLAN="EU868";  CLKSRC=1; RADIO0_FREQ=867500000; RADIO1_FREQ=868500000 ;;
    3) FREQ_PLAN="AU915";  CLKSRC=1; RADIO0_FREQ=904300000; RADIO1_FREQ=905000000 ;;
    *) FREQ_PLAN="US915";  CLKSRC=1; RADIO0_FREQ=904300000; RADIO1_FREQ=905000000 ;;
esac

echo ""
success "Configuration:"
echo "    Cluster:  $TTN_CLUSTER"
echo "    Freq:     $FREQ_PLAN"
echo "    EUI:      ${DETECTED_EUI:-<will be derived at runtime>}"
echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && echo "Aborted." && exit 0

# =============================================================================
# STEP 2 — System dependencies
# =============================================================================
header "Installing System Dependencies"

apt-get update -qq
apt-get install -y --no-install-recommends \
    git build-essential libssl-dev \
    python3 python3-libgpiod \
    curl ca-certificates
success "Dependencies installed"

# =============================================================================
# STEP 3 — Enable SPI1 overlay
# =============================================================================
header "Configuring SPI"

CONFIG_FILE=""
for f in /boot/firmware/config.txt /boot/config.txt; do
    [[ -f "$f" ]] && CONFIG_FILE="$f" && break
done
[[ -z "$CONFIG_FILE" ]] && error "Could not find config.txt"

if ! grep -q "spi1-3cs" "$CONFIG_FILE"; then
    echo "dtoverlay=spi1-3cs" >> "$CONFIG_FILE"
    success "Added spi1-3cs overlay to $CONFIG_FILE"
    REBOOT_NEEDED=1
else
    success "spi1-3cs overlay already present"
fi

if ! grep -q "dtparam=spi=on" "$CONFIG_FILE"; then
    echo "dtparam=spi=on" >> "$CONFIG_FILE"
    success "Enabled SPI in $CONFIG_FILE"
    REBOOT_NEEDED=1
fi

# Check if spidev1.2 is already available
if [[ ! -e /dev/spidev1.2 ]] && [[ -z "$REBOOT_NEEDED" ]]; then
    warn "/dev/spidev1.2 not found — a reboot may be needed after this script"
fi

# =============================================================================
# STEP 4 — Build sx1301_softreset
# =============================================================================
header "Building SX1301 Soft Reset Utility"

mkdir -p "$INSTALL_DIR"

gcc -O2 -o "$INSTALL_DIR/sx1301_softreset" "$SCRIPT_DIR/src/sx1301_softreset.c"
chmod +x "$INSTALL_DIR/sx1301_softreset"
success "Built sx1301_softreset (GPIO 38 hardware reset)"

# =============================================================================
# STEP 5 — Build LoRa Basics Station
# =============================================================================
header "Building LoRa Basics Station"

BUILD_DIR="$USER_HOME/basicstation"

if [[ ! -d "$BUILD_DIR" ]]; then
    info "Cloning basicstation..."
    sudo -u "$ACTUAL_USER" git clone https://github.com/lorabasics/basicstation.git "$BUILD_DIR"
else
    info "basicstation already cloned at $BUILD_DIR"
fi

# Patch setup.gmk for aarch64
SETUP_GMK="$BUILD_DIR/setup.gmk"
if grep -q "arm-linux-gnueabihf" "$SETUP_GMK"; then
    CURRENT_ARCH=$(gcc -dumpmachine)
    if [[ "$CURRENT_ARCH" == "aarch64-linux-gnu" ]]; then
        info "Patching setup.gmk for aarch64..."
        sed -i 's/ARCH\.rpi\s*=\s*arm-linux-gnueabihf/ARCH.rpi     = aarch64-linux-gnu/' "$SETUP_GMK"
        success "Patched setup.gmk: rpi platform now targets aarch64"
    fi
fi

# Remove existing platform dir to ensure patch is applied fresh
if [[ -d "$BUILD_DIR/deps/lgw/platform-rpi" ]]; then
    info "Removing existing platform-rpi to force clean rebuild..."
    rm -rf "$BUILD_DIR/deps/lgw/platform-rpi"
fi

info "Building basicstation (this takes a few minutes)..."
cd "$BUILD_DIR"
sudo -u "$ACTUAL_USER" make platform=rpi variant=std CC=gcc AR=ar LD=ld

STATION_BIN="$BUILD_DIR/build-rpi-std/bin/station"
[[ ! -f "$STATION_BIN" ]] && error "Build failed — binary not found at $STATION_BIN"
success "Built basicstation: $STATION_BIN"

# =============================================================================
# STEP 6 — Write config files
# =============================================================================
header "Writing Configuration Files"

# station.conf
cp "$SCRIPT_DIR/config/station.conf" "$INSTALL_DIR/station.conf"
success "Wrote station.conf"

# tc.uri
echo "wss://${TTN_CLUSTER}.cloud.thethings.network:8887" > "$INSTALL_DIR/tc.uri"
success "Wrote tc.uri (cluster: $TTN_CLUSTER)"

# tc.key
printf "Authorization: Bearer %s\n" "$TTN_API_KEY" > "$INSTALL_DIR/tc.key"
chmod 600 "$INSTALL_DIR/tc.key"
success "Wrote tc.key"

# tc.trust
info "Fetching Let's Encrypt CA certificate..."
curl -sSf -o "$INSTALL_DIR/tc.trust" \
    https://letsencrypt.org/certs/isrgrootx1.pem
success "Wrote tc.trust"

# =============================================================================
# STEP 7 — Write start.sh
# =============================================================================
header "Writing Startup Script"

# Substitute the actual station binary path into start.sh
sed "s|STATION_BIN  = \".*\"|STATION_BIN  = \"${STATION_BIN}\"|" \
    "$SCRIPT_DIR/start.sh" > "$INSTALL_DIR/start.sh"
chmod +x "$INSTALL_DIR/start.sh"
success "Wrote start.sh (LED + button + GPIO reset)"

# =============================================================================
# STEP 8 — Install systemd service
# =============================================================================
header "Installing systemd Service"

cp "$SCRIPT_DIR/systemd/ttn-station.service" /etc/systemd/system/ttn-station.service

# Patch the ExecStart path in case user installed to different location
sed -i "s|ExecStart=.*|ExecStart=${INSTALL_DIR}/start.sh|" \
    /etc/systemd/system/ttn-station.service

systemctl daemon-reload
systemctl enable ttn-station.service
success "Installed and enabled ttn-station.service"

# =============================================================================
# STEP 9 — Fix /var/tmp permissions
# =============================================================================
chmod 1777 /var/tmp

# =============================================================================
# Done
# =============================================================================
header "Setup Complete"

echo -e "${GREEN}${BOLD}Your Nebra Indoor Gen 1 is configured as a TTN gateway!${NC}"
echo ""
echo "  Gateway EUI:  ${DETECTED_EUI:-run: python3 -c \"import subprocess; mac=open('/sys/class/net/eth0/address').read().strip(); p=mac.split(':'); print((p[0]+p[1]+p[2]+'FFFE'+p[3]+p[4]+p[5]).upper())\"}"
echo "  Cluster:      $TTN_CLUSTER"
echo "  Install dir:  $INSTALL_DIR"
echo ""

if [[ -n "$REBOOT_NEEDED" ]]; then
    echo -e "${YELLOW}${BOLD}A reboot is required${NC} to activate the SPI overlay."
    echo "After reboot, the service will start automatically."
    echo ""
    read -rp "Reboot now? [Y/n]: " DO_REBOOT
    [[ "${DO_REBOOT,,}" != "n" ]] && reboot
else
    echo "Starting service now..."
    systemctl start ttn-station.service
    echo ""
    echo "Monitor logs with:"
    echo "  journalctl -u ttn-station -f"
fi
