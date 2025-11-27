# easyos

NixOS-based declarative appliance OS. Configure everything via `/etc/easy/config.json` and apply changes with a single command. A guided installer builds your system from the latest GitHub sources using Nix binary caches.

## Features

- Simple installation — Guided, destructive install with Btrfs subvolumes
- Network-first installer — Requires internet; prompts you to configure via `nmtui`
- Built-in help — Type `easy-help` for quick commands and docs
- Update channels — stable, beta, preview
- Web UI — http://<device-ip>:1234
- Hotspot mode — Open guest SSID for first-run (no WPA); captive portal on 1234; single concurrent session
- Backups — Automated Btrfs snapshots and backups to USB/external drives
- Storage expansion — Add drives and expand storage declaratively
- Optional encryption — LUKS2 with TPM2 auto-unlock and printed recovery key

## Quick start

### Build the ISO

On Linux with Docker or Podman:
```bash
git clone https://github.com/doughty247/easyos.git
cd easyos/easyos
./build-iso-docker.sh --ventoy  # Auto-copies to Ventoy USB if detected
```

### Install

1. Boot from the ISO
2. If prompted, configure network with `nmtui` (internet is required)
3. Run the guided installer (auto-runs on login, or `sudo /etc/easyos-install.sh`)
4. Choose hostname, admin user, and passwords
5. (Optional) Enable disk encryption with TPM2; save the printed recovery key (QR shown)
6. Reboot into your new system

### First boot

The system will:
- Auto-login as your admin user
- Start an open Wi‑Fi hotspot (if Wi‑Fi is present and no Ethernet)
- Expose a captive portal at http://10.42.0.1:1234/ (limited to one active client)
- Make the web UI available at http://<device-ip>:1234/

Type `easy-help` anytime to see available commands and documentation.

## Configuration

Edit `/etc/easy/config.json`:

```json
{
  "hostName": "easyos",
  "timeZone": "UTC",
  "swapMiB": 8192,
  "users": {
    "admin": {
      "name": "easyadmin",
      "authorizedKeys": ["ssh-ed25519 AAAA... you@example"]
    }
  },
  "mode": "first-run",
  "network": {
    "ssid": "EASY-Setup",
    "wifiChannel": "6",
    "clientIsolation": true
  },
  "backup": {
    "enable": true,
    "targetType": "local",
    "target": "/srv/backup",
    "onCalendar": "daily",
    "subvolumes": ["/", "/home", "/var"]
  }
}
```

Apply changes:
```bash
sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
```

## Useful commands

```bash
easy-help                              # Show quick reference
sudo nmtui                             # Configure network
sudo systemctl start easyos-hotspot    # Start Wi‑Fi hotspot
sudo systemctl start easyos-backup     # Run backup now
cat /etc/easy/channel                  # Check update channel
```

## Update channels

- stable — LTS kernel, stable features (recommended)
- beta — LTS kernel, beta features
- preview — Latest kernel, bleeding edge (manual build only)

## System architecture

- OS base — NixOS 24.11 with flakes
- Bootloader — systemd‑boot (UEFI) or GRUB (BIOS), auto‑selected by installer
- Filesystem — Btrfs with compression and subvolumes
- Network — NetworkManager for Wi‑Fi/Ethernet, captive portal on 1234 during setup
- Credentials — SHA‑512 hashed passwords set during installation (admin/root)
- Encryption — LUKS2 with TPM2 auto‑unlock (if selected) and recovery key

## Build from source

Containerized (recommended):
```bash
./build-iso-docker.sh          # Build ISO in container
./build-iso-docker.sh --vm     # Boot ISO in a VM for testing
./build-iso-docker.sh --ventoy # Auto-copy to Ventoy USB
```

## Support

Issues and pull requests welcome: https://github.com/doughty247/easyos

## License

MIT License – see [LICENSE](LICENSE).
