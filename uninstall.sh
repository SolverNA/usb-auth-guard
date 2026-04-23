#!/bin/bash
# usb-auth-guard uninstaller
# Usage: curl -fsSL https://raw.githubusercontent.com/SolVerNA/usb-auth-guard/master/uninstall.sh | sudo bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run with sudo: sudo bash uninstall.sh"

# ── Определяем реального пользователя (может быть root) ──────────────────────

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    # Запущено напрямую как root (не через sudo от обычного пользователя)
    REAL_USER="root"
fi
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null) || REAL_UID=0

info "Uninstalling usb-auth-guard (installed user: $REAL_USER)..."

# ── Останавливаем и отключаем пользовательский сервис ────────────────────────

info "Stopping user service..."
XDG_RUNTIME_DIR=/run/user/$REAL_UID
if [[ -d "$XDG_RUNTIME_DIR" ]]; then
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
        systemctl --user stop usb-auth-guard 2>/dev/null || true
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
        systemctl --user disable usb-auth-guard 2>/dev/null || true
else
    # XDG_RUNTIME_DIR не существует (нет живой сессии) — удаляем symlink напрямую
    SYSTEMD_USER_WANTS="/root/.config/systemd/user/default.target.wants"
    if [[ "$REAL_USER" != "root" ]]; then
        REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "")
        SYSTEMD_USER_WANTS="${REAL_HOME}/.config/systemd/user/default.target.wants"
    fi
    rm -f "${SYSTEMD_USER_WANTS}/usb-auth-guard.service" 2>/dev/null || true
    warn "No live user session found — disabled service by removing symlink"
fi

# ── Останавливаем и отключаем системные сервисы ──────────────────────────────

info "Stopping system services..."
systemctl stop    usbguard-dbus 2>/dev/null || true
systemctl disable usbguard-dbus 2>/dev/null || true
systemctl stop    usbguard      2>/dev/null || true
systemctl disable usbguard      2>/dev/null || true

# ── Удаляем установленные файлы ───────────────────────────────────────────────

info "Removing installed files..."
rm -f  /usr/local/bin/usb-auth-guard
rm -rf /usr/local/lib/usb-auth-guard
rm -f  /usr/share/polkit-1/actions/org.usbauthguard.policy
rm -f  /usr/lib/systemd/user/usb-auth-guard.service

# ── Удаляем конфиг USBGuard (опционально) ────────────────────────────────────

if [[ -f /etc/usbguard/rules.conf ]]; then
    echo ""
    read -r -p "  Remove /etc/usbguard/rules.conf (USBGuard policy)? [y/N] " yn
    case "$yn" in
        [Yy]*) rm -f /etc/usbguard/rules.conf; info "rules.conf removed." ;;
        *)     warn "Keeping /etc/usbguard/rules.conf" ;;
    esac
fi

# ── Удаляем пакеты ────────────────────────────────────────────────────────────

echo ""
read -r -p "  Remove usbguard package (apt-get remove usbguard)? [y/N] " yn
case "$yn" in
    [Yy]*)
        info "Removing usbguard..."
        apt-get remove -y usbguard usbguard-dbus 2>/dev/null || true
        ;;
    *)
        warn "Keeping usbguard package"
        ;;
esac

# ── Перезагружаем systemd ─────────────────────────────────────────────────────

systemctl daemon-reload

# ── Готово ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  usb-auth-guard uninstalled successfully!        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
