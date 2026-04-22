# usb-auth-guard

Blocks all USB devices by default and shows a **native polkit password dialog** before allowing any new device — just like `sudo` prompts in KDE/GNOME.

Protects against:
- **BadUSB / Rubber Ducky / O.MG Cable** — HID injection keyboards are blocked until you auth
- **USB data exfiltration** — drives do nothing without your password
- **Physical access attacks** — cloning your device's VID:PID doesn't help, it still needs auth

```
Insert USB → USBGuard blocks at kernel level
                    ↓
         usb-auth-guard daemon detects event
                    ↓
         Native KDE/GNOME polkit dialog appears
                    ↓
    Correct password → device works
    Cancel / wrong  → device stays dead
```

## Install

### One-liner (Debian / Kali / Ubuntu)

```bash
curl -fsSL https://raw.githubusercontent.com/SolVerNA/usb-auth-guard/main/install.sh | sudo bash
```

### .deb package

```bash
wget https://github.com/SolVerNA/usb-auth-guard/releases/latest/download/usb-auth-guard_1.0.0.deb
sudo dpkg -i usb-auth-guard_1.0.0.deb
systemctl --user enable --now usb-auth-guard
```

### From source

```bash
git clone https://github.com/SolVerNA/usb-auth-guard
cd usb-auth-guard
sudo make install
sudo make setup-usbguard
systemctl --user enable --now usb-auth-guard
```

## Requirements

- `usbguard` + `usbguard-dbus`
- `python3-dbus`, `python3-gi`
- `policykit-1` (polkit)
- `curl` (for installer script)
- systemd + KDE Plasma or GNOME (any polkit agent)

## How it works

| Component | Role |
|---|---|
| **USBGuard** | Blocks devices at kernel level via `/sys/.../authorized` |
| **usbguard-dbus** | Exposes USBGuard events on D-Bus |
| **usb-auth-guard** | Python daemon listening for `DevicePresenceChanged` |
| **polkit + pkexec** | Shows native desktop password dialog |
| **helper** | Root-level helper called by pkexec to run `usbguard allow-device` |

Authorization is **per-session only** — plugging the same device again requires re-auth.

## Logs

```bash
journalctl --user -u usb-auth-guard -f
```

## Uninstall

```bash
git clone https://github.com/SolVerNA/usb-auth-guard
cd usb-auth-guard
sudo make uninstall
```

## License

MIT
