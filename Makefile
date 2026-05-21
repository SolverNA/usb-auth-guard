NAME    = usb-auth-guard
VERSION = 1.0.0
PKGDIR  = $(NAME)_$(VERSION)
DESTDIR ?=
PREFIX  ?= /usr/local

INSTALL_MARKER = /var/lib/usb-auth-guard/.installed
BACKUP_DIR = /var/lib/usb-auth-guard/backup

.PHONY: all install uninstall deb clean

all:
	@echo "Targets: install, uninstall, deb, clean"
	@echo ""
	@echo "Recommended installation:"
	@echo "  curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/install.sh | sudo bash"

install:
	@# Check for double installation
	@if [ -f "$(INSTALL_MARKER)" ]; then \
		echo "ERROR: usb-auth-guard is already installed!"; \
		echo "Run 'sudo make uninstall' first."; \
		exit 1; \
	fi

	@echo "==> Installing $(NAME)..."

	@# Create directories
	mkdir -p $(BACKUP_DIR)

	@# Backup existing configs
	@if [ -f /etc/usbguard/usbguard-daemon.conf ]; then \
		cp /etc/usbguard/usbguard-daemon.conf $(BACKUP_DIR)/ 2>/dev/null || true; \
	fi
	@if [ -f /etc/usbguard/rules.conf ]; then \
		cp /etc/usbguard/rules.conf $(BACKUP_DIR)/ 2>/dev/null || true; \
	fi

	@# Install files
	install -Dm755 src/usb-auth-guard     $(DESTDIR)$(PREFIX)/bin/usb-auth-guard
	install -Dm755 src/helper             $(DESTDIR)$(PREFIX)/lib/usb-auth-guard/helper
	install -Dm755 src/helper-trusted     $(DESTDIR)$(PREFIX)/lib/usb-auth-guard/helper-trusted
	install -Dm644 src/org.usbauthguard.policy \
	    $(DESTDIR)/usr/share/polkit-1/actions/org.usbauthguard.policy
	install -Dm644 src/usb-auth-guard.service \
	    $(DESTDIR)/usr/lib/systemd/user/usb-auth-guard.service

	@# Install sudoers entry (substitute $$SUDO_USER, validate with visudo)
	@if [ -n "$$SUDO_USER" ] && [ "$$SUDO_USER" != "root" ]; then \
		tmp=$$(mktemp); \
		sed "s|{{USER}}|$$SUDO_USER|g" src/usb-auth-guard.sudoers > $$tmp; \
		if visudo -c -f $$tmp >/dev/null 2>&1; then \
			install -Dm440 $$tmp $(DESTDIR)/etc/sudoers.d/usb-auth-guard; \
			echo "==> Installed sudoers entry for $$SUDO_USER"; \
		else \
			echo "==> sudoers validation failed, skipping fast-path"; \
		fi; \
		rm -f $$tmp; \
	else \
		echo "==> SUDO_USER unset, skipping sudoers entry"; \
	fi

	@# Create usbguard group
	@getent group usbguard > /dev/null 2>&1 || groupadd --system usbguard

	@# Generate rules for connected devices
	@echo ""
	@echo "  IMPORTANT: Make sure your keyboard and mouse are connected NOW."
	@echo "  All currently connected devices will be trusted."
	@echo ""
	@read -p "  Press Enter when ready..." _
	@echo ""
	usbguard generate-policy > /etc/usbguard/rules.conf
	@echo "==> Trusted devices:"
	@grep "^allow" /etc/usbguard/rules.conf | grep -o 'name "[^"]*"' | head -10 || true
	@echo ""

	@# Configure usbguard (AFTER rules are generated)
	@if [ -f /etc/usbguard/usbguard-daemon.conf ]; then \
		sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=apply-policy/' /etc/usbguard/usbguard-daemon.conf; \
		sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=block/' /etc/usbguard/usbguard-daemon.conf; \
	fi

	@# Enable services
	systemctl daemon-reload
	systemctl enable --now usbguard usbguard-dbus 2>/dev/null || true

	@# Mark installation
	date '+%Y-%m-%d %H:%M:%S' > $(INSTALL_MARKER)

	@echo ""
	@echo "==> Done! Now run:"
	@echo "    systemctl --user enable --now usb-auth-guard"
	@echo ""

uninstall:
	@echo "==> Uninstalling $(NAME)..."

	@# FIRST: Restore safe policy
	@if [ -f /etc/usbguard/usbguard-daemon.conf ]; then \
		sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=allow/' /etc/usbguard/usbguard-daemon.conf; \
		sed -i 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=apply-policy/' /etc/usbguard/usbguard-daemon.conf; \
	fi
	systemctl reload usbguard 2>/dev/null || systemctl restart usbguard 2>/dev/null || true

	@# Stop user service
	systemctl --user stop usb-auth-guard 2>/dev/null || true
	systemctl --user disable usb-auth-guard 2>/dev/null || true

	@# Remove files
	rm -f  $(PREFIX)/bin/usb-auth-guard
	rm -rf $(PREFIX)/lib/usb-auth-guard
	rm -f  /usr/share/polkit-1/actions/org.usbauthguard.policy
	rm -f  /usr/lib/systemd/user/usb-auth-guard.service
	rm -f  /etc/sudoers.d/usb-auth-guard

	@# Remove marker
	rm -f $(INSTALL_MARKER)
	rm -rf /var/lib/usb-auth-guard

	systemctl daemon-reload

	@echo "==> Uninstalled. USB policy set to 'allow' - all devices work."

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
