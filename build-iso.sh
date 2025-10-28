#!/usr/bin/env bash
set -euo pipefail

# EASYOS ISO Builder
# Run this inside a NixOS distrobox or on a NixOS system

echo "Building easyos ISO..."
echo "====================="
echo ""

# Check if we're in the right directory
if [ ! -f "flake.nix" ]; then
  echo "ERROR: Run this script from the easyos repo root" >&2
  exit 1
fi

# Build the ISO
echo "Building ISO (this may take a while)..."
nix build .#nixosConfigurations.iso.config.system.build.isoImage \
  --impure \
  --print-build-logs

if [ $? -eq 0 ]; then
  ISO=$(find result/iso -name "*.iso" -type f | head -1)
  if [ -n "$ISO" ]; then
    echo ""
    echo "✓ ISO built successfully!"
    echo "  Location: $ISO"
    echo ""
    echo "Next steps:"
    echo "  1. Write to USB: dd if=$ISO of=/dev/sdX bs=4M status=progress"
    echo "  2. Or test in VM: qemu-system-x86_64 -cdrom $ISO -m 2048 -enable-kvm"
    echo ""
    echo "  Inside the ISO, run: sudo /etc/easyos-install.sh"
  else
    echo "ERROR: ISO file not found in result/" >&2
    exit 1
  fi
else
  echo "ERROR: ISO build failed" >&2
  exit 1
fi
