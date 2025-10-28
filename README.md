# easyos (WIP)

NixOS-based rewrite of EASY as a declarative appliance. A single JSON file at `/etc/easy/config.json` drives the system. Apply changes with an impure rebuild.

## Installation

See **[INSTALL.md](INSTALL.md)** for complete installation options:

- **Fresh Install from ISO** — Build a bootable ISO using Docker on Bazzite, test in VM or write to USB
- **Remote Install** — Clone and apply on an existing NixOS system
- **Development/Testing** — Build and test locally without installing

Also see **[DOCKER.md](DOCKER.md)** for detailed Docker build workflow on Bazzite.

## Quick start (existing NixOS)

1) Clone and prepare config:
```bash
sudo git clone https://github.com/YOUR_USERNAME/easyos.git /etc/nixos/easyos
sudo cp /etc/nixos/easyos/etc/easy/config.example.json /etc/easy/config.json
sudo nano /etc/easy/config.json  # customize hostname, keys, etc.
```

2) Apply configuration:
```bash
sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
```

Note: `--impure` is required because we read `/etc/easy/config.json` at evaluation time.

## What’s included

- Core headless server baseline (systemd-boot, systemd-networkd, OpenSSH hardened, PipeWire)
- Home Manager baseline for the admin user
- Hotspot/guest mode (hostapd + dnsmasq + captive stub) when `mode` is `first-run` or `guest`
- Btrfs backups (send/receive) via service + timer (local or SSH target)
- Btrfs storage expansion helper (device add + balance to RAID1 or selected profile)

## JSON schema (minimal)

```json
{
  "hostName": "easyos",
  "timeZone": "UTC",
  "swapMiB": 4096,
  "users": {
    "admin": {
      "name": "easyadmin",
      "authorizedKeys": ["ssh-ed25519 AAAA... you@example"]
    }
  },
  "mode": "normal", // "first-run" | "guest" | "normal"
  "network": {
    "interface": "wlan0",
    "ssid": "EASY-Setup",
    "psk": "changeme-strong-pass"
  },
  "backup": {
    "enable": true,
    "targetType": "local",  // "local" | "ssh"
    "target": "/srv/backup",  // or "user@host:/path" when targetType = "ssh"
    "onCalendar": "daily",
    "subvolumes": ["/", "/home", "/var"]
  },
  "storage": {
    "auto": false,
    "devices": ["/dev/sdb", "/dev/sdc"],
    "mountPoint": "/",
    "profile": "raid1"       // e.g., raid1 | single | raid5 | raid6
  }
}
```

## Notes

- Hotspot: AP runs on the `network.interface` with a basic captive landing page on port 8088 (nginx). Firewall blocks forwarding from hotspot to WAN by default.
- Backups: Creates read-only snapshots and sends them to the target. Keeps snapshot staging for 7 days in `/var/lib/easyos/backup-snaps`.
- Storage expansion: One-shot service adds listed devices to the Btrfs at `mountPoint` and converts/balances to the selected `profile`. A guard file at `/var/lib/easyos/.storage-expand-done` prevents repeat runs.

## Try it

**Build the ISO:**
```bash
# In a NixOS distrobox on Bazzite
./build-iso.sh
```

**Preview flake outputs:**
```bash
nix flake show
```

**Test in a VM:**
```bash
nixos-rebuild build-vm --impure --flake .#easyos
./result/bin/run-*-vm
```

## Roadmap

- Replace captive stub with real web UI editing `/etc/easy/config.json` and triggering rebuilds
- Service modules for Nextcloud, Immich, and Guardian-like health checks
- Update flow aligned to flakes (auto updates with snapshots and rollback)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. Issues and PRs welcome!

## License

MIT License - see [LICENSE](LICENSE) for details.
