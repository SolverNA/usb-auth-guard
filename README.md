# usb-auth-guard

Blocks all USB devices by default and shows a **native polkit password dialog** before allowing any new device.

Protects against:
- **BadUSB / Rubber Ducky / O.MG Cable** — HID injection blocked until auth
- **USB data exfiltration** — drives require password
- **Physical access attacks** — VID:PID spoofing doesn't help

```
Insert USB → USBGuard blocks it
                ↓
      usb-auth-guard detects event
                ↓
      Password dialog appears
                ↓
  Correct password → device works
  Cancel / wrong   → device stays blocked
```

## Install (Debian / Ubuntu / Kali)

```bash
curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/install.sh | sudo bash
```

Then either:
- **Log out and log back in** (recommended), or
- Run: `systemctl --user start usb-auth-guard`

The service needs to start inside your graphical session for the dialog to appear.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/SolverNA/usb-auth-guard/master/uninstall.sh | sudo bash
```

## Troubleshooting

### No password prompt appears

```bash
# Check service status
systemctl --user status usb-auth-guard
journalctl --user -u usb-auth-guard -f

# Check usbguard-dbus
sudo systemctl status usbguard-dbus
```

### Keyboard/mouse blocked after install

```bash
# Temporarily allow all devices
sudo sed -i 's/InsertedDevicePolicy=.*/InsertedDevicePolicy=allow/' /etc/usbguard/usbguard-daemon.conf
sudo systemctl restart usbguard

# Reconnect devices, regenerate rules
sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf

# Re-enable blocking
sudo sed -i 's/InsertedDevicePolicy=.*/InsertedDevicePolicy=block/' /etc/usbguard/usbguard-daemon.conf
sudo systemctl restart usbguard
```

### View logs

```bash
journalctl --user -u usb-auth-guard -f   # user service
sudo journalctl -u usbguard -f           # usbguard
```

## Alternative install methods

### From source (git clone)

```bash
git clone https://github.com/SolverNA/usb-auth-guard
cd usb-auth-guard
sudo make install
systemctl --user enable --now usb-auth-guard
```

### Build .deb package

```bash
git clone https://github.com/SolverNA/usb-auth-guard
cd usb-auth-guard
make deb
sudo apt install ./usb-auth-guard_1.0.0.deb
systemctl --user enable --now usb-auth-guard
```

## How it works

| Component | Role |
|-----------|------|
| **USBGuard** | Blocks devices at kernel level |
| **usbguard-dbus** | Exposes events on D-Bus |
| **usb-auth-guard** | Python daemon listening for events |
| **polkit + pkexec** | Native password dialog |
| **helper** | Root helper for `usbguard allow-device` |

Authorization is **per-session only** — same device requires re-auth next time.

## Requirements

- Debian/Ubuntu/Kali or compatible
- systemd
- Python 3 + dbus + gi
- polkit

## License

MIT
