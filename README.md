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
curl -fsSL https://raw.githubusercontent.com/SolVerNA/usb-auth-guard/master/install.sh | sudo bash
```

> **After the script finishes:** log out and log back into your desktop session, **or** open a terminal and run `systemctl --user start usb-auth-guard`.
> The service needs to start inside your graphical session so that the polkit dialog can appear on screen.

### .deb package (build from source)

```bash
# if needed:
# sudo apt-get install -y git make dpkg-dev
git clone https://github.com/SolVerNA/usb-auth-guard
cd usb-auth-guard
make deb
sudo apt install -y ./usb-auth-guard_1.0.0.deb   # installs usbguard and all other dependencies automatically
sudo make setup-usbguard                           # trust currently connected devices, put USBGuard into block mode
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
- `policykit-1` **or** `polkitd` + `pkexec`
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
# from repo directory:
sudo make uninstall
```

After uninstall, USBGuard is reset to `allow` mode — all USB devices will work
normally with no auth dialogs. USBGuard itself is left installed (system package).

## ⚠️ Important

Do NOT manually run `apt purge usbguard usbguard-dbus` to uninstall.
Use `sudo make uninstall` only — it safely removes usb-auth-guard
without touching system packages that SDDM and polkit depend on.

## License

MIT
