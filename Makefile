NAME    = usb-auth-guard
VERSION = 1.0.0
PKGDIR  = $(NAME)_$(VERSION)
DESTDIR ?=
PREFIX  ?= /usr/local

.PHONY: all install uninstall deb clean

all:
	@echo "Targets: install, uninstall, deb, clean"

install:
	@echo "==> Installing $(NAME)..."

	# Основной демон
	install -Dm755 src/usb-auth-guard     $(DESTDIR)$(PREFIX)/bin/usb-auth-guard

	# Helper для pkexec
	install -Dm755 src/helper             $(DESTDIR)$(PREFIX)/lib/usb-auth-guard/helper

	# Polkit policy
	install -Dm644 src/org.usbauthguard.policy \
	    $(DESTDIR)/usr/share/polkit-1/actions/org.usbauthguard.policy

	# Systemd user service (для всех пользователей)
	install -Dm644 src/usb-auth-guard.service \
	    $(DESTDIR)/usr/lib/systemd/user/usb-auth-guard.service

	@echo ""
	@echo "==> Done! Now run:"
	@echo "    sudo make setup-usbguard    # настроить USBGuard"
	@echo "    systemctl --user enable --now usb-auth-guard"
	@echo ""

# Настройка USBGuard (отдельная цель, требует sudo)
setup-usbguard:
	@echo "==> Setting up USBGuard..."
	@echo ""
	@echo "  IMPORTANT: Make sure your keyboard and mouse are connected RIGHT NOW."
	@echo "  All currently connected devices will be added to the allowlist."
	@echo "  Any device plugged in LATER will require password authentication."
	@echo ""
	@read -p "  Press Enter when ready (all needed devices are plugged in)..." _

	# Создаём группу
	getent group usbguard > /dev/null 2>&1 || groupadd --system usbguard

	# Генерируем правила для ВСЕХ сейчас подключённых устройств
	# (не фильтруем hotplug — пользователь сам решает что подключить перед setup)
	usbguard generate-policy > /etc/usbguard/rules.conf
	@echo "==> Saved rules for currently connected devices:"
	@cat /etc/usbguard/rules.conf | grep "^allow" | grep -o 'name "[^"]*"' || true
	@echo ""

	# Конфигурация демона
	sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=block/' \
	    /etc/usbguard/usbguard-daemon.conf 2>/dev/null || true
	sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=block/' \
	    /etc/usbguard/usbguard-daemon.conf 2>/dev/null || true

	systemctl enable --now usbguard usbguard-dbus
	systemctl restart usbguard usbguard-dbus

	# Restart usb-auth-guard for all logged-in users so they pick up the
	# new usbguard-dbus instance (the old D-Bus match rule is now stale).
	@for uid in $$(loginctl list-users 2>/dev/null | awk 'NR>1 && /^[[:space:]]*[0-9]+[[:space:]]/{print $$1}'); do \
	    user=$$(id -un $$uid 2>/dev/null) || continue; \
	    systemctl --user -M $$uid@ restart usb-auth-guard 2>/dev/null && \
	        echo "    Restarted usb-auth-guard for user $$user" || true; \
	done

	@echo "==> USBGuard configured!"
	@echo "    Devices connected NOW are trusted. New devices will require auth."

uninstall:
	@echo "==> Uninstalling $(NAME)..."
	systemctl --user stop usb-auth-guard 2>/dev/null || true
	systemctl --user disable usb-auth-guard 2>/dev/null || true
	rm -f  $(PREFIX)/bin/usb-auth-guard
	rm -rf $(PREFIX)/lib/usb-auth-guard
	rm -f  /usr/share/polkit-1/actions/org.usbauthguard.policy
	rm -f  /usr/lib/systemd/user/usb-auth-guard.service
	systemctl daemon-reload
	# Возвращаем USBGuard в разрешительный режим — без нашего демона
	# новые устройства некому авторизовать, поэтому блокировка снимается
	sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=allow/' \
	    /etc/usbguard/usbguard-daemon.conf 2>/dev/null || true
	sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=allow/' \
	    /etc/usbguard/usbguard-daemon.conf 2>/dev/null || true
	systemctl reload-or-restart usbguard 2>/dev/null || true
	# НЕ делаем purge usbguard — это системный пакет
	@echo "==> Uninstalled. USBGuard left intact; policies reset to 'allow' so all USB devices work."
	@echo "    Re-run 'sudo make setup-usbguard' if you reinstall usb-auth-guard later."

# Собрать .deb пакет
deb:
	@echo "==> Building .deb package..."
	rm -rf $(PKGDIR)
	mkdir -p $(PKGDIR)/DEBIAN
	mkdir -p $(PKGDIR)/usr/local/bin
	mkdir -p $(PKGDIR)/usr/local/lib/usb-auth-guard
	mkdir -p $(PKGDIR)/usr/share/polkit-1/actions
	mkdir -p $(PKGDIR)/usr/lib/systemd/user

	cp debian/control   $(PKGDIR)/DEBIAN/control
	cp debian/postinst  $(PKGDIR)/DEBIAN/postinst
	cp debian/prerm     $(PKGDIR)/DEBIAN/prerm
	chmod 755 $(PKGDIR)/DEBIAN/postinst $(PKGDIR)/DEBIAN/prerm

	cp src/usb-auth-guard          $(PKGDIR)/usr/local/bin/usb-auth-guard
	cp src/helper                  $(PKGDIR)/usr/local/lib/usb-auth-guard/helper
	cp src/org.usbauthguard.policy $(PKGDIR)/usr/share/polkit-1/actions/
	cp src/usb-auth-guard.service  $(PKGDIR)/usr/lib/systemd/user/

	chmod 755 $(PKGDIR)/usr/local/bin/usb-auth-guard
	chmod 755 $(PKGDIR)/usr/local/lib/usb-auth-guard/helper
	chmod 644 $(PKGDIR)/usr/share/polkit-1/actions/org.usbauthguard.policy
	chmod 644 $(PKGDIR)/usr/lib/systemd/user/usb-auth-guard.service

	dpkg-deb --build --root-owner-group $(PKGDIR)
	@echo "==> Built: $(PKGDIR).deb"

clean:
	rm -rf $(PKGDIR) *.deb
