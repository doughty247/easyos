# easeOS

<p align="center">
  <img src="assets/logo.svg" alt="easeOS mascot" width="120">
</p>

**A home server you can set and forget.**

Install it once. Add your apps. Stop worrying about it. Updates won't break things. If something goes wrong, undo it from the boot menu.

<p align="center">
  <img src="https://img.shields.io/badge/NixOS_24.11-5277C3?style=flat-square&logo=nixos" alt="NixOS 24.11">
  <img src="https://img.shields.io/badge/MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/Alpha-orange?style=flat-square" alt="Alpha">
</p>

---

<p align="center">
  <img src="screenshots/home-day.png" alt="Home view" width="280">
  <img src="screenshots/garden-sunset.png" alt="Garden view" width="280">
  <img src="screenshots/store-night.png" alt="Seed Store" width="280">
</p>

---

## What You Get

- **Web UI** at `http://<ip>:1234` — install apps, change settings, no terminal needed
- **Seed Store** — one-click installs: Immich, Nextcloud, Home Assistant, Jellyfin, Vaultwarden
- **Undo button** — every update is reversible from the boot menu
- **Encrypted by default** — full disk, auto-unlocks on your hardware
- **Automatic backups** — just plug in a drive
- **WiFi setup** — boots into hotspot, walks you through config

---

## Why Not CasaOS/Umbrel/Unraid?

They make Docker pretty. But when an update breaks something, you're restoring backups and crossing your fingers.

easeOS lets you undo. Pick a previous version from the boot menu and you're back. No restore, no downtime, no stress.

---

## Quick Start

```bash
git clone https://github.com/doughty247/easyos.git
cd easyos/easyos
./build-iso-docker.sh --vm      # test in VM
./build-iso-docker.sh --ventoy  # or copy to USB
```

Boot → follow installer → access `http://<ip>:1234`

---

## Requirements

x86_64, 4GB+ RAM, 32GB+ SSD. Works on mini PCs, old laptops, NUCs.

---

## Roadmap

Done: Web UI, Seed Store, encryption, backups

Next: Pre-built ISOs, ARM64/Pi 5, Tailscale

---

## Links

[Seed Store SDK](store/SDK.md) · [Issues](https://github.com/doughty247/easyos/issues) · [Discussions](https://github.com/doughty247/easyos/discussions)

MIT License
