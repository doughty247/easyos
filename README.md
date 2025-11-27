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

## The Problem with Self-Hosting Today

**CasaOS, Umbrel, TrueNAS Scale, Unraid** — they all solve the "make Docker pretty" problem. But:

- Update breaks something? Hope you have backups.
- New server? Reinstall everything manually.
- What changed since last week? No idea.
- Mix of Docker + native apps? Good luck.

These tools are **wrappers**, not operating systems. They can't protect you from themselves.

---

## How easeOS is Different

### Declarative, Not Imperative

Your entire system — OS, apps, configs — is defined in one place. This isn't a gimmick:

```
Traditional: "Install app A, then configure X, then install B..."
easeOS:      "The system has apps A and B with these configs." (done)
```

The system figures out how to get there. Every time. Reproducibly.

### Atomic Updates with Rollback

Every change creates a new system generation. The old one stays bootable.

```bash
# Something went wrong after an update?
sudo nixos-rebuild switch --rollback

# Or just pick a previous generation from the boot menu
```

No snapshots to manage. No backup/restore dance. Just... undo.

### Repair, Don't Reinstall

Corrupted config? Weird state? Just rebuild:

```bash
sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
```

The system converges to the declared state. Every file, every service, every permission — rebuilt exactly as specified. This is what "infrastructure as code" actually means.

### Clone Your Entire Server

Moving to new hardware? Your system is a ~50KB flake:

1. Copy `/etc/nixos/easyos` to new machine
2. Run the installer
3. Done. Identical system.

No migration tools. No export/import. Just... the same system.

---

## But What About the Simple Stuff?

Yes, you still get the friendly parts:

- **Web UI** at `http://<ip>:1234` — manage apps without terminal
- **Seed Store** — one-click installs for Immich, Nextcloud, Home Assistant, etc.
- **Auto-setup** — boots into WiFi hotspot, guides you through config
- **TPM2 encryption** — full disk encryption with auto-unlock
- **Btrfs snapshots** — automated backups built in

The difference is what's underneath. When the web UI can't help, you're not stranded.

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

## The Technical Bits

| Component | Choice | Why |
|-----------|--------|-----|
| Base OS | NixOS 24.11 | Declarative, reproducible, rollback |
| Filesystem | Btrfs | Snapshots, compression, expansion |
| Boot | systemd-boot / GRUB | Auto-selected, both work |
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

- 📦 [Create apps for the Seed Store](store/SDK.md)
- 🐛 [Report issues](https://github.com/doughty247/easyos/issues)
- 💬 [Discussions](https://github.com/doughty247/easyos/discussions)

---

## License

MIT — do what you want.

---

<p align="center">
  <em>Self-hosting that doesn't make you the sysadmin.</em>
</p>
