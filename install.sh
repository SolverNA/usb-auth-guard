#!/bin/bash
# usb-auth-guard installer
# Usage: curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/install.sh | sudo bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

# Marker file to track installation state
INSTALL_MARKER="/var/lib/usb-auth-guard/.installed"
BACKUP_DIR="/var/lib/usb-auth-guard/backup"

# ── TTY handling for pipe mode ─────────────────────────────────────────────────
TTY_FD=""
if exec {TTY_FD}</dev/tty 2>/dev/null; then
    : # TTY available
else
    TTY_FD=""
fi

ask_enter() {
    local prompt="$1"
    if [[ -n "$TTY_FD" ]]; then
        read -r -p "$prompt" _ <&"$TTY_FD" || true
    else
        warn "No interactive TTY - waiting 5 seconds instead..."
        warn "Make sure your keyboard/mouse are connected!"
        sleep 5
    fi
}

cleanup_tty() {
    if [[ -n "$TTY_FD" ]]; then
        exec {TTY_FD}<&- 2>/dev/null || true
    fi
}
trap cleanup_tty EXIT

# ── Rollback function ──────────────────────────────────────────────────────────
rollback() {
    warn "Installation failed! Rolling back..."

    # Stop services
    systemctl stop usbguard 2>/dev/null || true
    systemctl stop usbguard-dbus 2>/dev/null || true

    # Restore backup config if exists
    if [[ -f "$BACKUP_DIR/usbguard-daemon.conf" ]]; then
        cp "$BACKUP_DIR/usbguard-daemon.conf" /etc/usbguard/usbguard-daemon.conf 2>/dev/null || true
        info "Restored original usbguard-daemon.conf"
    fi
    if [[ -f "$BACKUP_DIR/rules.conf" ]]; then
        cp "$BACKUP_DIR/rules.conf" /etc/usbguard/rules.conf 2>/dev/null || true
        info "Restored original rules.conf"
    fi

    # Remove installed files
    rm -f /usr/local/bin/usb-auth-guard
    rm -rf /usr/local/lib/usb-auth-guard
    rm -f /usr/share/polkit-1/actions/org.usbauthguard.policy
    rm -f /usr/lib/systemd/user/usb-auth-guard.service
    rm -f "$INSTALL_MARKER"

    # Restart usbguard with safe policy
    if [[ -f /etc/usbguard/usbguard-daemon.conf ]]; then
        sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=allow/' /etc/usbguard/usbguard-daemon.conf || true
        sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=allow/' /etc/usbguard/usbguard-daemon.conf || true
    fi
    systemctl restart usbguard 2>/dev/null || true

    error "Rollback complete. Please check system state."
}

# ── Pre-flight checks ──────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && error "Run with sudo: curl -fsSL ... | sudo bash"

# Check for double installation
if [[ -f "$INSTALL_MARKER" ]]; then
    echo ""
    warn "usb-auth-guard is already installed!"
    warn "To reinstall, first run uninstall.sh"
    echo ""
    echo "  Uninstall: curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/uninstall.sh | sudo bash"
    echo ""
    exit 1
fi

# Check if daemon is already running (another sign of existing install)
if [[ -f /usr/local/bin/usb-auth-guard ]]; then
    warn "Found existing /usr/local/bin/usb-auth-guard"
    warn "Looks like a previous installation exists. Please uninstall first."
    exit 1
fi

command -v python3   >/dev/null || error "python3 not found. Install: apt install python3"
command -v systemctl >/dev/null || error "systemd not found. This tool requires systemd."

# ── Dependencies ───────────────────────────────────────────────────────────────

info "Installing dependencies..."
apt-get update -qq 2>/dev/null || warn "apt-get update failed (continuing)"

apt-get install -y usbguard python3-dbus python3-gi curl 2>/dev/null || \
    error "Failed to install dependencies. Check your internet connection."

# polkit package
apt-get install -y policykit-1 2>/dev/null || \
apt-get install -y polkitd pkexec 2>/dev/null || \
    error "Could not install polkit."
command -v pkexec >/dev/null || error "pkexec not found after installation."

# Dialog tools (optional)
apt-get install -y kde-cli-tools 2>/dev/null || \
apt-get install -y zenity 2>/dev/null || \
    warn "kdialog/zenity not found - polkit dialogs still work"

# usbguard-dbus (may be bundled)
apt-get install -y usbguard-dbus 2>/dev/null || \
    info "usbguard-dbus bundled in usbguard - OK"

# ── Create directories and backup ─────────────────────────────────────────────

mkdir -p "$BACKUP_DIR"
mkdir -p /usr/local/lib/usb-auth-guard

# Backup existing configs
if [[ -f /etc/usbguard/usbguard-daemon.conf ]]; then
    cp /etc/usbguard/usbguard-daemon.conf "$BACKUP_DIR/" 2>/dev/null || true
fi
if [[ -f /etc/usbguard/rules.conf ]]; then
    cp /etc/usbguard/rules.conf "$BACKUP_DIR/" 2>/dev/null || true
fi

# ── Download files ─────────────────────────────────────────────────────────────

INSTALL_DIR="$(mktemp -d)"
REPO_URL="https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master"

info "Downloading files..."
curl -fsSL "$REPO_URL/src/usb-auth-guard"          -o "$INSTALL_DIR/usb-auth-guard" || error "Download failed"
curl -fsSL "$REPO_URL/src/helper"                  -o "$INSTALL_DIR/helper" || error "Download failed"
curl -fsSL "$REPO_URL/src/org.usbauthguard.policy" -o "$INSTALL_DIR/org.usbauthguard.policy" || error "Download failed"
curl -fsSL "$REPO_URL/src/usb-auth-guard.service"  -o "$INSTALL_DIR/usb-auth-guard.service" || error "Download failed"

# ── Generate rules FIRST (before any blocking) ────────────────────────────────

info "Configuring USBGuard..."

# Create usbguard group if missing
getent group usbguard >/dev/null 2>&1 || groupadd --system usbguard

echo ""
warn "IMPORTANT: Make sure your keyboard and mouse are connected NOW!"
warn "All currently connected USB devices will be trusted."
warn "Any device plugged in AFTER this will require password."
echo ""
ask_enter "  Press Enter when all your devices are connected..."
echo ""

# Generate rules BEFORE enabling block policy
info "Generating rules for connected devices..."
if ! usbguard generate-policy > /tmp/usb-rules-new.conf 2>/dev/null; then
    error "Failed to generate USBGuard policy. Is usbguard installed correctly?"
fi

# Check that rules were generated
if [[ ! -s /tmp/usb-rules-new.conf ]]; then
    warn "No USB devices detected! Rules file is empty."
    warn "This might lock you out. Aborting for safety."
    rm -f /tmp/usb-rules-new.conf
    error "No devices found. Connect keyboard/mouse and retry."
fi

# Show what will be trusted
info "Devices that will be trusted:"
grep "^allow" /tmp/usb-rules-new.conf | grep -o 'name "[^"]*"' 2>/dev/null | head -10 || echo "  (device names not available)"
echo ""

# Apply rules
cp /tmp/usb-rules-new.conf /etc/usbguard/rules.conf
rm -f /tmp/usb-rules-new.conf
info "Rules saved to /etc/usbguard/rules.conf"

# ── Install files ──────────────────────────────────────────────────────────────

info "Installing files..."
install -Dm755 "$INSTALL_DIR/usb-auth-guard"          /usr/local/bin/usb-auth-guard
install -Dm755 "$INSTALL_DIR/helper"                  /usr/local/lib/usb-auth-guard/helper
install -Dm644 "$INSTALL_DIR/org.usbauthguard.policy" /usr/share/polkit-1/actions/org.usbauthguard.policy
install -Dm644 "$INSTALL_DIR/usb-auth-guard.service"  /usr/lib/systemd/user/usb-auth-guard.service

rm -rf "$INSTALL_DIR"

# ── Configure USBGuard policy (AFTER rules are in place) ──────────────────────

CONF=/etc/usbguard/usbguard-daemon.conf
if [[ -f "$CONF" ]]; then
    # Set blocking policy - safe now because rules.conf has our devices
    sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=apply-policy/' "$CONF" || true
    sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=block/' "$CONF" || true
    info "USBGuard configured: new devices will be blocked until authorized"
fi

# ── Enable services ────────────────────────────────────────────────────────────

info "Enabling services..."
systemctl daemon-reload

# Enable and start system services
systemctl enable usbguard 2>/dev/null || warn "Could not enable usbguard"
systemctl enable usbguard-dbus 2>/dev/null || warn "Could not enable usbguard-dbus"

# Restart to apply new config
systemctl restart usbguard 2>/dev/null || {
    warn "Failed to restart usbguard - attempting rollback"
    rollback
}
systemctl restart usbguard-dbus 2>/dev/null || warn "usbguard-dbus restart failed"

# User service - enable only (will start on next login)
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    REAL_UID=$(id -u "$REAL_USER" 2>/dev/null) || REAL_UID=""
    if [[ -n "$REAL_UID" && -d "/run/user/$REAL_UID" ]]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user daemon-reload 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user enable usb-auth-guard 2>/dev/null || \
            warn "Could not enable user service"
    else
        warn "User session not active - enable manually after login:"
        warn "  systemctl --user enable usb-auth-guard"
    fi
fi

# ── Mark installation complete ─────────────────────────────────────────────────

date '+%Y-%m-%d %H:%M:%S' > "$INSTALL_MARKER"
info "Installation marker created"

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  usb-auth-guard installed successfully!                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  Next steps:${NC}"
echo ""
echo "  1. Log out and log back in (recommended)"
echo "     OR run now: systemctl --user start usb-auth-guard"
echo ""
echo "  2. Plug in a USB device - you should see a password prompt"
echo ""
echo "  Logs:      journalctl --user -u usb-auth-guard -f"
echo "  Uninstall: curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/uninstall.sh | sudo bash"
echo ""
