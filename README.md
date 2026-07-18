# usb-auth-guard

Blocks all USB devices by default and shows a **native polkit password dialog** before allowing any new device.

Protects against:
- **BadUSB / Rubber Ducky / O.MG Cable** — HID injection blocked until auth
- **USB data exfiltration** — drives require password
- **Physical access attacks** — every new device is blocked until you authenticate

> **Trust windows:** the grace clock starts when an authorized device is
> **unplugged**; a matching re-insertion within the window skips the password:
> - **Same VID:PID — 60s**, on any port (unplug/replug a stick, iPhone switching
>   modes).
> - **Same physical port — 5s** (firmware flashing drops the device and brings it
>   back on the same socket with a *changed* VID:PID: bootloader/DFU/app modes).
>
> The clock deliberately starts at **unplug**, not at authorization — a device can
> stay connected through a long flash and only re-enumerate at the very end. The
> port window is short on purpose: trusting a socket auto-allows anything plugged
> there, so 5s only bridges the re-enumeration gap, not long enough to pull the
> device and swap in a BadUSB on the same port. Only an *already-authorized*
> device's removal arms a window, and every other port still prompts. It's a
> deliberate convenience/security trade-off.
>
> **Denying a prompt revokes trust:** if you deny a device that was authorized
> earlier in the session, its trust windows are disarmed — a replug prompts
> again instead of being auto-allowed. After a denial the same device also
> stays blocked without new dialogs for ~45s, so a rapidly re-enumerating
> device can't spam password prompts (failed prompts count toward
> `pam_faillock` and could otherwise lock your account). Prompts are shown one
> at a time; extra re-enumerations of the same device while a dialog is open
> are folded into it.

```
Insert USB → USBGuard blocks it
                ↓
      usb-auth-guard detects event
                ↓
      Password dialog appears
                ↓
  Correct password → device works
  Cancel / wrong   → device stays blocked
                     (no re-prompt for ~45s; prior trust revoked)
```

## Supported distributions

| Distro | Status |
|--------|--------|
| Debian / Ubuntu / Kali | ✅ Supported |
| Arch Linux / Manjaro | ✅ Supported |
| Other systemd-based | ⚠️ May work (manual dependency install required) |

The installer auto-detects `pacman` or `apt-get` and uses the correct package names.

## Install

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
# Allow all devices temporarily
sudo sed -i 's/ImplicitPolicyTarget=.*/ImplicitPolicyTarget=allow/' /etc/usbguard/usbguard-daemon.conf
sudo systemctl restart usbguard

# Reconnect devices, regenerate rules
sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf

# Re-enable blocking
sudo sed -i 's/ImplicitPolicyTarget=.*/ImplicitPolicyTarget=block/' /etc/usbguard/usbguard-daemon.conf
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

### Build .deb package (Debian/Ubuntu only)

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

- systemd
- Python 3
- polkit / pkexec
- **Arch / Manjaro:** `usbguard` `python-dbus` `python-gobject`
- **Debian / Ubuntu:** `usbguard` `python3-dbus` `python3-gi`

All dependencies are installed automatically by the installer.

## License

MIT
