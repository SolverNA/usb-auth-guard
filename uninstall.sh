#!/bin/bash
# usb-auth-guard uninstaller
# Usage: curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/uninstall.sh | sudo bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

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

pkg_remove() {
    case "$PKG_MANAGER" in
        pacman) pacman -R --noconfirm "$@" 2>/dev/null || true ;;
        apt)    apt-get remove -y "$@" 2>/dev/null || true ;;
        *)      warn "Unknown package manager. Remove manually: $*" ;;
    esac
}

# ── TTY handling ───────────────────────────────────────────────────────────────
TTY_FD=""
if exec {TTY_FD}</dev/tty 2>/dev/null; then
    : # TTY available
else
    TTY_FD=""
fi

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local yn=""

    if [[ -n "$TTY_FD" ]]; then
        read -r -p "$prompt" yn <&"$TTY_FD" || yn=""
    else
        warn "No interactive TTY - using default: $default"
        yn="$default"
    fi

    [[ "$yn" =~ ^[Yy] ]]
}

cleanup_tty() {
    if [[ -n "$TTY_FD" ]]; then
        exec {TTY_FD}<&- 2>/dev/null || true
    fi
}
trap cleanup_tty EXIT

# ── Pre-flight checks ──────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && error "Run with sudo: curl -fsSL ... | sudo bash"

# Check if installed
if [[ ! -f "$INSTALL_MARKER" && ! -f /usr/local/bin/usb-auth-guard ]]; then
    warn "usb-auth-guard does not appear to be installed."
    warn "Nothing to uninstall."
    exit 0
fi

info "Uninstalling usb-auth-guard..."
info "Detected package manager: $PKG_MANAGER"

# ── FIRST: Restore safe USB policy (before stopping anything) ─────────────────

info "Restoring safe USB policy..."
CONF=/etc/usbguard/usbguard-daemon.conf
if [[ -f "$CONF" ]]; then
    # Make all USB devices work again BEFORE we stop services
    # Handles commented-out, existing, and missing keys.
    # InsertedDevicePolicy only supports: apply-policy | block | reject (not allow).
    # Set ImplicitPolicyTarget=allow so unmatched devices are permitted,
    # effectively restoring pre-installation "allow everything" behaviour.
    sed -i "s|^#\?PresentDevicePolicy=.*|PresentDevicePolicy=allow|" "$CONF" 2>/dev/null || true
    sed -i "s|^#\?InsertedDevicePolicy=.*|InsertedDevicePolicy=apply-policy|" "$CONF" 2>/dev/null || true
    if grep -qE "^#?ImplicitPolicyTarget=" "$CONF" 2>/dev/null; then
        sed -i "s|^#\?ImplicitPolicyTarget=.*|ImplicitPolicyTarget=allow|" "$CONF" 2>/dev/null || true
    else
        echo "ImplicitPolicyTarget=allow" >> "$CONF"
    fi
    info "USBGuard policy set to 'allow' - all USB devices will work"
fi

# Reload usbguard config (without stopping it)
systemctl reload usbguard 2>/dev/null || \
    systemctl restart usbguard 2>/dev/null || \
    warn "Could not reload usbguard config"

# ── Stop user service ──────────────────────────────────────────────────────────

info "Stopping user service..."

REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    REAL_UID=$(id -u "$REAL_USER" 2>/dev/null) || REAL_UID=""
    if [[ -n "$REAL_UID" && -d "/run/user/$REAL_UID" ]]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user stop usb-auth-guard 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user disable usb-auth-guard 2>/dev/null || true
        info "User service stopped and disabled"
    fi
fi

# Also try to stop for all logged-in users
for uid_dir in /run/user/*; do
    [[ -d "$uid_dir" ]] || continue
    uid=$(basename "$uid_dir")
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    user=$(id -un "$uid" 2>/dev/null) || continue
    sudo -u "$user" XDG_RUNTIME_DIR="$uid_dir" \
        systemctl --user stop usb-auth-guard 2>/dev/null || true
    sudo -u "$user" XDG_RUNTIME_DIR="$uid_dir" \
        systemctl --user disable usb-auth-guard 2>/dev/null || true
done

# Remove user service symlinks (in case session is not active)
for home_dir in /home/*; do
    [[ -d "$home_dir" ]] || continue
    rm -f "$home_dir/.config/systemd/user/default.target.wants/usb-auth-guard.service" 2>/dev/null || true
done
rm -f /root/.config/systemd/user/default.target.wants/usb-auth-guard.service 2>/dev/null || true

# ── Remove installed files ─────────────────────────────────────────────────────

info "Removing installed files..."
rm -f  /usr/local/bin/usb-auth-guard
rm -rf /usr/local/lib/usb-auth-guard
rm -f  /usr/share/polkit-1/actions/org.usbauthguard.policy
rm -f  /usr/lib/systemd/user/usb-auth-guard.service

# Reload systemd
systemctl daemon-reload 2>/dev/null || true

# ── Remove installation marker and backups ─────────────────────────────────────

rm -f "$INSTALL_MARKER"
rm -rf /var/lib/usb-auth-guard

info "Installation files removed"

# ── Optional: Remove usbguard rules ────────────────────────────────────────────

echo ""
if [[ -f /etc/usbguard/rules.conf ]]; then
    if ask_yes_no "  Remove /etc/usbguard/rules.conf (trusted device list)? [y/N] " "n"; then
        rm -f /etc/usbguard/rules.conf
        info "rules.conf removed"
    else
        info "Keeping rules.conf"
    fi
fi

# ── Optional: Disable usbguard completely ──────────────────────────────────────

echo ""
if ask_yes_no "  Disable usbguard service completely? [y/N] " "n"; then
    systemctl stop usbguard 2>/dev/null || true
    systemctl stop usbguard-dbus 2>/dev/null || true
    systemctl disable usbguard 2>/dev/null || true
    systemctl disable usbguard-dbus 2>/dev/null || true
    info "usbguard disabled"
else
    info "Keeping usbguard enabled (but with 'allow' policy - all USB devices work)"
fi

# ── Optional: Remove usbguard package ──────────────────────────────────────────

echo ""
if ask_yes_no "  Remove usbguard package? [y/N] " "n"; then
    if [[ "$PKG_MANAGER" == "pacman" ]]; then
        pkg_remove usbguard
    elif [[ "$PKG_MANAGER" == "apt" ]]; then
        pkg_remove usbguard usbguard-dbus
    else
        warn "Unknown package manager. Remove usbguard manually."
    fi
    info "usbguard package removed"
else
    info "Keeping usbguard package"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  usb-auth-guard uninstalled successfully!                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  All USB devices should now work without password prompts."
echo ""
