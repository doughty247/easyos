# easeOS

<p align="center">
  <img src="assets/logo.svg" alt="easeOS mascot" width="120">
</p>

**The home server that fixes itself.**

Built on NixOS. Your entire system is code. Break something? Roll back in seconds. New hardware? Clone your setup in minutes.

<p align="center">
  <img src="https://img.shields.io/badge/NixOS_24.11-5277C3?style=flat-square&logo=nixos" alt="NixOS 24.11">
  <img src="https://img.shields.io/badge/MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/Alpha-orange?style=flat-square" alt="Alpha">
</p>

---

## What You Get

- **Web UI** at `http://<ip>:1234` — install apps, change settings, no terminal needed
- **Seed Store** — one-click installs: Immich, Nextcloud, Home Assistant, Jellyfin, Vaultwarden
- **Atomic rollback** — every update is reversible from the boot menu
- **TPM2 encryption** — full disk, auto-unlocks on your hardware
- **Btrfs snapshots** — automated backups, just add a drive
- **WiFi setup mode** — boots into hotspot, captive portal walks you through config

---

## Why Not CasaOS/Umbrel/Unraid?

They're Docker wrappers. When updates break things, you restore backups and hope.

easeOS rebuilds your entire system from a declaration. Same result every time. Move to new hardware by copying one folder.

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

Done: Web UI, Seed Store, TPM2 encryption, Btrfs backups

Next: Pre-built ISOs, ARM64/Pi 5, Tailscale

---

## Links

[Seed Store SDK](store/SDK.md) · [Issues](https://github.com/doughty247/easyos/issues) · [Discussions](https://github.com/doughty247/easyos/discussions)

MIT License
