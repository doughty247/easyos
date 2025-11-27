# easeOS

**The home server that fixes itself.**

Most self-hosting solutions give you a dashboard on top of Docker and call it a day. When something breaks, you're on your own. easeOS is different — it's built on NixOS, which means your entire system is defined in code and can be rebuilt identically at any time.

> **Break something? Roll back in seconds.**  
> **New hardware? Clone your entire setup.**  
> **Curious what changed? Diff any two system states.**

<p align="center">
  <img src="https://img.shields.io/badge/Built_on-NixOS_24.11-5277C3?style=flat-square&logo=nixos" alt="NixOS 24.11">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/Status-Alpha-orange?style=flat-square" alt="Alpha">
</p>

---

## Why Not CasaOS, Umbrel, or Unraid?

They solve the "make Docker pretty" problem. But:

- Update breaks something? Hope you have backups.
- New server? Reinstall everything manually.
- What changed since last week? No idea.

These tools are **wrappers**, not operating systems. They can't protect you from themselves.

---

## Features

### Seed Store
Browse and install self-hosted apps with one click. Each app is pre-configured to work out of the box:
- **Immich** — Google Photos replacement with AI search
- **Nextcloud** — Files, calendar, contacts
- **Home Assistant** — Smart home automation
- **Jellyfin** — Media streaming
- **Vaultwarden** — Password manager

### Web Interface
Manage your server from any browser at `http://<ip>:1234`:
- Install and configure apps
- Monitor system status
- Adjust settings
- No SSH required (but it's there when you need it)

### Atomic Updates with Rollback
Every change creates a new system generation. The old one stays bootable.

```bash
# Something broke? Undo it.
sudo nixos-rebuild switch --rollback
```

No snapshots to manage. No backup/restore dance. Just... undo.

### Repair, Don't Reinstall
Weird state? Just rebuild. The system converges to the declared state — every file, every service, every permission.

```bash
sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
```

This is what "infrastructure as code" actually means.

### Clone Your Entire Server
Moving to new hardware? Your system is a ~50KB flake:

1. Copy `/etc/nixos/easyos` to new machine
2. Run the installer
3. Done. Identical system.

### Secure by Default
- Full-disk encryption with TPM2 auto-unlock
- Firewall configured out of the box
- Client isolation on guest networks

### Bulletproof Storage
- Btrfs with compression and snapshots
- Automated daily backups
- Easy expansion — just add drives

### Zero-Config Networking
- Auto-creates WiFi hotspot for initial setup
- Captive portal guides you through config
- Automatic network optimization (CAKE QoS, BBR)

---

## Quick Start

```bash
# Build the ISO (any Linux with Docker/Podman)
git clone https://github.com/doughty247/easyos.git
cd easyos/easyos
./build-iso-docker.sh --vm    # Test in VM first

# Or with --ventoy to copy to USB
./build-iso-docker.sh --ventoy
```

### Installation
1. Boot from USB
2. Connect to network (prompted if needed)
3. Follow the guided installer
4. Access web UI at `http://<your-ip>:1234`

---

## Who Should Use This?

**Use easeOS if:**
- You've been burned by updates that break things
- You want to actually understand your system
- You plan to run this for years, not months
- You value reliability over "move fast and break things"

**Maybe not for you if:**
- You want to click buttons and never see a terminal
- You're happy with Docker + Portainer
- You need ARM support today (coming soon)

---

## System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | x86_64, 2 cores | 4+ cores |
| RAM | 4 GB | 8+ GB |
| Storage | 32 GB SSD | 256+ GB SSD |
| Network | Ethernet or WiFi | Gigabit Ethernet |

Works great on: Mini PCs, old laptops, Intel NUCs

---

## Technical Details

| Component | Choice | Why |
|-----------|--------|-----|
| Base OS | NixOS 24.11 | Declarative, reproducible, rollback |
| Filesystem | Btrfs | Snapshots, compression, expansion |
| Boot | systemd-boot / GRUB | Auto-selected |
| Encryption | LUKS2 + TPM2 | Modern, hardware-backed |
| Network | NetworkManager | Just works |
| Apps | Native NixOS modules | Not containers pretending to be native |

---

## Roadmap

- [x] Declarative NixOS base with flakes
- [x] Web UI for configuration
- [x] Seed Store for app installs
- [x] TPM2 disk encryption
- [x] Automated Btrfs backups
- [ ] Pre-built ISO downloads
- [ ] ARM64 / Raspberry Pi 5
- [ ] Remote access via Tailscale
- [ ] System migration wizard

---

## Contributing

- [Create apps for the Seed Store](store/SDK.md)
- [Report issues](https://github.com/doughty247/easyos/issues)
- [Discussions](https://github.com/doughty247/easyos/discussions)

---

## License

MIT — do what you want.

---

<p align="center">
  <em>Self-hosting that doesn't make you the sysadmin.</em>
</p>
