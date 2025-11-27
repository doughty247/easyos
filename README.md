# easeOS

**Your personal cloud, simplified.**

easeOS is a self-hosted home server operating system that makes running your own cloud services as easy as using commercial alternatives — but with full privacy and control. No subscriptions, no data harvesting, no vendor lock-in.

Built on NixOS, easeOS combines the reliability of declarative configuration with the simplicity of a consumer appliance. Install apps like Immich (Google Photos replacement), Nextcloud, Home Assistant, or Jellyfin with a single click. Everything just works.

<p align="center">
  <img src="https://img.shields.io/badge/NixOS-24.11-5277C3?style=flat-square&logo=nixos" alt="NixOS 24.11">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/Status-Alpha-orange?style=flat-square" alt="Alpha">
</p>

---

## Why easeOS?

| Problem | easeOS Solution |
|---------|-----------------|
| Self-hosting is complicated | One-click app installs via web UI |
| Server setup takes hours | 10-minute guided installer |
| Configuration files are confusing | Visual settings, no terminal required |
| Updates break things | Atomic updates with automatic rollback |
| Backups are an afterthought | Built-in automated backups |
| Security is hard to get right | TPM2 encryption, automatic updates |

## Features

### 🌱 **Seed Store** — Install apps instantly
Browse and install self-hosted apps from the built-in store. Each app is pre-configured to work out of the box:
- **Immich** — Google Photos alternative with AI-powered search
- **Nextcloud** — Files, calendar, contacts, and more
- **Home Assistant** — Smart home automation
- **Jellyfin** — Media streaming for your library
- **Vaultwarden** — Password manager (Bitwarden-compatible)

### 🖥️ **Web Interface**
Manage your server from any browser — no SSH required:
- Install and configure apps
- Monitor system status
- Adjust settings
- View logs and troubleshoot

### 🔒 **Secure by Default**
- Optional full-disk encryption with TPM2 auto-unlock
- Automatic security updates
- Firewall configured out of the box
- Client isolation on guest networks

### 💾 **Bulletproof Storage**
- Btrfs filesystem with compression and snapshots
- Automated daily backups
- Easy storage expansion — just add drives
- Snapshot rollback if something goes wrong

### 📶 **Zero-Config Networking**
- Auto-creates WiFi hotspot for initial setup
- Captive portal guides you through configuration
- Automatic network optimization (CAKE QoS, BBR)
- Works with Ethernet or WiFi

---

## Quick Start

### Option 1: Download ISO (Coming Soon)
Pre-built ISOs will be available for direct download.

### Option 2: Build from Source

On any Linux system with Docker or Podman:

```bash
git clone https://github.com/doughty247/easyos.git
cd easyos/easyos
./build-iso-docker.sh --vm    # Build and test in VM
```

### Installation

1. Boot from USB (Ventoy recommended)
2. Connect to network (prompted if needed)
3. Follow the guided installer
4. Access web UI at `http://<your-ip>:1234`

---

## Who is this for?

**easeOS is perfect for:**
- 🏠 Families who want to own their photos, not rent cloud storage
- 🔐 Privacy-conscious users replacing Google/Apple services
- 🎬 Media enthusiasts building a home streaming server
- 🏡 Smart home users wanting local-only automation
- 💻 Developers who want a reproducible home lab

**easeOS might not be for you if:**
- You need enterprise-grade clustering or HA
- You prefer managing everything via terminal
- You're running mission-critical production workloads

---

## System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | x86_64, 2 cores | 4+ cores |
| RAM | 4 GB | 8+ GB |
| Storage | 32 GB SSD | 256+ GB SSD |
| Network | Ethernet or WiFi | Gigabit Ethernet |

Works great on: Mini PCs, old laptops, Intel NUCs, Raspberry Pi 5 (coming soon)

---

## Documentation

- **[Installation Guide](docs/installation.md)** — Step-by-step setup
- **[App Store SDK](store/SDK.md)** — Create your own apps
- **[Configuration Reference](docs/configuration.md)** — All settings explained
- **[Troubleshooting](docs/troubleshooting.md)** — Common issues and fixes

---

## Roadmap

- [x] Core OS with NixOS flakes
- [x] Web UI for configuration
- [x] Seed Store for one-click app installs
- [x] TPM2 encryption support
- [x] Automated backups
- [ ] Pre-built ISO downloads
- [ ] ARM64 / Raspberry Pi support
- [ ] Mobile app for remote access
- [ ] Tailscale integration
- [ ] App data migration tools

---

## Contributing

easeOS is open source and contributions are welcome!

- 🐛 [Report bugs](https://github.com/doughty247/easyos/issues)
- 💡 [Request features](https://github.com/doughty247/easyos/discussions)
- 🔧 [Submit pull requests](https://github.com/doughty247/easyos/pulls)
- 📦 [Create apps for the Seed Store](store/SDK.md)

---

## License

MIT License — see [LICENSE](LICENSE)

---

<p align="center">
  <strong>Take back your data. Own your cloud.</strong><br>
  <a href="https://github.com/doughty247/easyos">GitHub</a> •
  <a href="https://github.com/doughty247/easyos/discussions">Community</a>
</p>
