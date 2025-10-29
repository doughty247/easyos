# easyos

NixOS-based declarative appliance OS. Configure everything via `/etc/easy/config.json` and apply changes with a single command.

## Features

- **Simple Installation** — Guided installer with automatic partitioning and setup
- **Easy Network Setup** — Automatic Wi-Fi scanning and configuration via nmtui
- **Built-in Help** — Type `easy-help` for quick commands and documentation
- **Update Channels** — Choose stable, beta, or preview channels
- **Web UI** — Manage your system via browser at http://localhost:8080
- **Hotspot Mode** — Automatic Wi-Fi access point for initial setup (post-install)
- **Btrfs Backups** — Automated snapshots and backups to USB/external drives
- **Storage Expansion** — Add drives and expand storage dynamically

## Quick Start

### Building the ISO

On a Linux system with Docker/Podman:
```bash
git clone https://github.com/doughty247/easyos.git
cd easyos
./build-iso-docker.sh --ventoy  # Auto-copies to Ventoy USB if detected
```

### Installation

1. Boot from the ISO
2. Connect to network (automatically prompted if needed)
3. Follow the guided installer
4. Set your hostname, username, and passwords
5. Choose your update channel (stable/beta/preview)
6. Reboot into your new system

### First Boot

On first boot, the system will:
- Auto-login as your chosen admin user
- Display setup options and helpful commands
- Start the Wi-Fi hotspot if Wi-Fi hardware is available (no Ethernet)
- Make the web UI available at your device's IP

Type `easy-help` anytime to see available commands and documentation.

## Configuration

Edit `/etc/easy/config.json` to configure your system:

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
    "psk": "easyos123"
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

## Useful Commands

```bash
easy-help                      # Show all available commands
sudo nmtui                     # Configure network connections
sudo systemctl start easyos-hotspot   # Start Wi-Fi hotspot
sudo systemctl start easyos-backup    # Run backup now
cat /etc/easy/channel          # Check your update channel
```

## Update Channels

- **stable** — LTS kernel, stable features (recommended)
- **beta** — LTS kernel, beta features
- **preview** — Latest kernel, bleeding edge (manual build only)

## System Architecture

- **OS Base** — NixOS 24.11 with flakes
- **Bootloader** — systemd-boot (UEFI only)
- **Filesystem** — Btrfs with compression and subvolumes
- **Network** — NetworkManager for easy Wi-Fi/Ethernet management
- **Credentials** — SHA-512 hashed passwords set during installation

## Building from Source

**Docker/Podman method (recommended):**
```bash
./build-iso-docker.sh          # Build ISO in container
./build-iso-docker.sh --vm     # Copy to VM directory
./build-iso-docker.sh --ventoy # Auto-copy to Ventoy USB
```

**Native NixOS:**
```bash
nix build .#isoImage-stable    # Build stable channel ISO
nix build .#isoImage-beta      # Build beta channel ISO
```

## Support

Issues and pull requests welcome at https://github.com/doughty247/easyos

## License

MIT License - see [LICENSE](LICENSE) for details.
