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

# ── Package manager detection ──────────────────────────────────────────────────

if command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
else
    PKG_MANAGER="unknown"
fi

pkg_update() {
    case "$PKG_MANAGER" in
        pacman) pacman -Sy --noconfirm 2>/dev/null || warn "pacman -Sy failed (continuing)" ;;
        apt)    apt-get update -qq 2>/dev/null    || warn "apt-get update failed (continuing)" ;;
        *)      warn "Unknown package manager, skipping cache update" ;;
    esac
}

# Returns 0 on success, 1 on failure — callers decide whether to error or warn
pkg_install() {
    case "$PKG_MANAGER" in
        pacman) pacman -S --noconfirm --needed "$@" 2>/dev/null ;;
        apt)    apt-get install -y "$@" 2>/dev/null ;;
        *)      warn "Unknown package manager. Install manually: $*"; return 1 ;;
    esac
}

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
    local rb_conf=/etc/usbguard/usbguard-daemon.conf
    if [[ -f "$rb_conf" ]]; then
        sed -i "s|^#\?PresentDevicePolicy=.*|PresentDevicePolicy=allow|" "$rb_conf" || true
        sed -i "s|^#\?InsertedDevicePolicy=.*|InsertedDevicePolicy=apply-policy|" "$rb_conf" || true
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

command -v python3   >/dev/null || error "python3 not found."
command -v systemctl >/dev/null || error "systemd not found. This tool requires systemd."

info "Detected package manager: $PKG_MANAGER"

# ── Dependencies ───────────────────────────────────────────────────────────────

info "Installing dependencies..."
pkg_update

if [[ "$PKG_MANAGER" == "pacman" ]]; then
    # Arch / Manjaro package names
    pkg_install usbguard python-dbus python-gobject curl || \
        error "Failed to install dependencies. Check your internet connection."

    # polkit is usually pre-installed on KDE Plasma; install if missing
    pkg_install polkit || warn "polkit install failed (may already be installed)"

    # On Arch, usbguard-dbus service is bundled with the usbguard package
    info "usbguard-dbus is bundled with usbguard on Arch/Manjaro - OK"

    # Dialog tools (optional — polkit dialogs work without these)
    # On Arch/Manjaro, kdialog is a separate package (not part of kde-cli-tools)
    pkg_install kdialog  || \
        pkg_install zenity || \
        warn "kdialog/zenity not found - polkit dialogs still work"

elif [[ "$PKG_MANAGER" == "apt" ]]; then
    # Debian / Ubuntu package names
    pkg_install usbguard python3-dbus python3-gi curl || \
        error "Failed to install dependencies. Check your internet connection."

    # polkit package (name differs across Ubuntu versions)
    pkg_install policykit-1 || \
        pkg_install polkitd pkexec || \
        error "Could not install polkit."

    # Dialog tools (optional)
    pkg_install kde-cli-tools || \
        pkg_install zenity      || \
        warn "kdialog/zenity not found - polkit dialogs still work"

    # usbguard-dbus may be a separate package on Debian/Ubuntu
    pkg_install usbguard-dbus || \
        info "usbguard-dbus bundled in usbguard - OK"
else
    warn "Unsupported package manager. Make sure these are installed manually:"
    warn "  usbguard, python-dbus (or python3-dbus), python-gobject (or python3-gi), polkit, curl"
fi

command -v pkexec >/dev/null || error "pkexec not found after installation."

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
    # Set blocking policy — handles commented-out, existing, and missing keys
    set_conf_key() {
        local key="$1" val="$2"
        if grep -qE "^#?${key}=" "$CONF"; then
            sed -i "s|^#\?${key}=.*|${key}=${val}|" "$CONF"
        else
            echo "${key}=${val}" >> "$CONF"
        fi
    }
    set_conf_key PresentDevicePolicy apply-policy
    set_conf_key InsertedDevicePolicy block
    info "USBGuard configured: new devices will be blocked until authorized"
fi

# ── Enable services ────────────────────────────────────────────────────────────

info "Enabling services..."
systemctl daemon-reload

# Enable and start system services
systemctl enable usbguard 2>/dev/null || warn "Could not enable usbguard"
systemctl enable usbguard-dbus 2>/dev/null || warn "Could not enable usbguard-dbus (may not exist as a separate unit)"

# Restart to apply new config
systemctl restart usbguard 2>/dev/null || {
    warn "Failed to restart usbguard - attempting rollback"
    rollback
}
systemctl restart usbguard-dbus 2>/dev/null || warn "usbguard-dbus restart failed (may be bundled)"

# User service - enable and try to start
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    REAL_UID=$(id -u "$REAL_USER" 2>/dev/null) || REAL_UID=""
    if [[ -n "$REAL_UID" && -d "/run/user/$REAL_UID" ]]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user daemon-reload 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user enable --now usb-auth-guard 2>/dev/null && \
            info "User service started" || \
            warn "Could not start user service - run: systemctl --user start usb-auth-guard"
    else
        warn "User session not active - start manually after login:"
        warn "  systemctl --user enable --now usb-auth-guard"
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
echo "  1. Plug in a USB device - you should see a password prompt"
echo ""
echo "  If no prompt appears, run: systemctl --user start usb-auth-guard"
echo "  Or log out and log back in."
echo ""
echo "  Logs:      journalctl --user -u usb-auth-guard -f"
echo "  Uninstall: curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/uninstall.sh | sudo bash"
echo ""
