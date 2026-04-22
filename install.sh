#!/bin/bash
# usb-auth-guard installer
# Usage: curl -fsSL https://raw.githubusercontent.com/SolVerNA/usb-auth-guard/master/install.sh | sudo bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[x]${NC} $*"; exit 1; }

# ── Проверки ──────────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && error "Run with sudo: sudo bash install.sh"
command -v python3   > /dev/null || error "python3 not found"
command -v systemctl > /dev/null || error "systemd not found"

# ── Зависимости ───────────────────────────────────────────────────────────────

info "Installing dependencies..."
apt-get update -qq 2>/dev/null || warn "apt-get update had errors (continuing anyway)"
apt-get install -y usbguard python3-dbus python3-gi curl 2>/dev/null || \
    error "apt-get failed. Check your internet connection."

# policykit package name differs across distros (e.g. Kali uses polkitd/pkexec)
apt-get install -y policykit-1 2>/dev/null || \
apt-get install -y polkitd pkexec 2>/dev/null || \
apt-get install -y pkexec 2>/dev/null || \
    error "Could not install polkit (policykit-1/polkitd/pkexec)."
command -v pkexec >/dev/null || error "pkexec is required but was not found."

# kdialog (KDE) или zenity (GNOME) — для fallback уведомлений
apt-get install -y kde-cli-tools 2>/dev/null || \
apt-get install -y zenity        2>/dev/null || \
    warn "Neither kdialog nor zenity found — polkit dialogs still work"

# usbguard-dbus может быть отдельным пакетом или встроенным
apt-get install -y usbguard-dbus 2>/dev/null || \
    info "usbguard-dbus is bundled in usbguard — OK"

# ── Файлы ────────────────────────────────────────────────────────────────────

INSTALL_DIR="$(mktemp -d)"
REPO_URL="https://raw.githubusercontent.com/SolVerNA/usb-auth-guard/master"

info "Downloading files..."
curl -fsSL "$REPO_URL/src/usb-auth-guard"            -o "$INSTALL_DIR/usb-auth-guard"
curl -fsSL "$REPO_URL/src/helper"                    -o "$INSTALL_DIR/helper"
curl -fsSL "$REPO_URL/src/org.usbauthguard.policy"   -o "$INSTALL_DIR/org.usbauthguard.policy"
curl -fsSL "$REPO_URL/src/usb-auth-guard.service"    -o "$INSTALL_DIR/usb-auth-guard.service"

info "Installing files..."
install -Dm755 "$INSTALL_DIR/usb-auth-guard"          /usr/local/bin/usb-auth-guard
install -Dm755 "$INSTALL_DIR/helper"                  /usr/local/lib/usb-auth-guard/helper
install -Dm644 "$INSTALL_DIR/org.usbauthguard.policy" /usr/share/polkit-1/actions/org.usbauthguard.policy
install -Dm644 "$INSTALL_DIR/usb-auth-guard.service"  /usr/lib/systemd/user/usb-auth-guard.service

# ── USBGuard настройка ────────────────────────────────────────────────────────

info "Configuring USBGuard..."

# Группа
getent group usbguard > /dev/null 2>&1 || groupadd --system usbguard

# Генерируем rules.conf — только hardwired (клава/мышь не включаем)
echo ""
warn "Make sure your keyboard and mouse are plugged in right now!"
warn "All currently connected devices will be permanently trusted."
warn "Any device plugged in AFTER this will require password auth."
echo ""
read -r -p "  Press Enter when all your devices are connected..." _
echo ""

usbguard generate-policy 2>/dev/null > /etc/usbguard/rules.conf || true
info "Trusted devices saved to /etc/usbguard/rules.conf"
grep "^allow" /etc/usbguard/rules.conf | grep -o 'name "[^"]*"' 2>/dev/null || true

# daemon.conf — убеждаемся что политика block
CONF=/etc/usbguard/usbguard-daemon.conf
if [ -f "$CONF" ]; then
    sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=block/'   "$CONF" || true
    sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=block/' "$CONF" || true
fi

# ── Сервисы ──────────────────────────────────────────────────────────────────

info "Enabling services..."
systemctl daemon-reload
systemctl enable --now usbguard     2>/dev/null || warn "Could not enable usbguard"
systemctl enable --now usbguard-dbus 2>/dev/null || warn "Could not enable usbguard-dbus"

# User service — только enable, НЕ --now
# Если запустить через su -l здесь, сервис стартует без DISPLAY/XAUTHORITY/DBUS_SESSION_BUS_ADDRESS
# и pkexec не сможет отобразить диалог. Сервис должен стартовать в живой графической сессии.
REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")

# Reload и enable (без --now) — сервис автоматически поднимется при следующем логине
sudo -u "$REAL_USER" XDG_RUNTIME_DIR=/run/user/$REAL_UID \
    systemctl --user daemon-reload 2>/dev/null || true
sudo -u "$REAL_USER" XDG_RUNTIME_DIR=/run/user/$REAL_UID \
    systemctl --user enable usb-auth-guard 2>/dev/null || \
    warn "Could not enable user service — run manually: systemctl --user enable usb-auth-guard"

# ── Готово ────────────────────────────────────────────────────────────────────

rm -rf "$INSTALL_DIR"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  usb-auth-guard installed successfully!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  ⚠  Action required:${NC}"
echo "  The user service must start inside your graphical (desktop) session."
echo "  Choose one of:"
echo ""
echo "    a) Log out and log back in  ← recommended, service starts automatically"
echo ""
echo "    b) Or, right now in your desktop terminal:"
echo "         systemctl --user start usb-auth-guard"
echo ""
echo "  Check logs:    journalctl --user -u usb-auth-guard -f"
echo "  Uninstall:     curl -fsSL https://raw.githubusercontent.com/SolVerNA/usb-auth-guard/master/uninstall.sh | sudo bash"
echo ""
