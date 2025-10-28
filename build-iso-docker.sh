#!/usr/bin/env bash
set -euo pipefail

# EASYOS ISO Builder (Docker/Podman version)
# For use on Bazzite or other non-NixOS systems

# Parse arguments
VENTOY_COPY=false
VM_TEST=false
SUPPRESS_XATTR_WARNINGS=false

for arg in "$@"; do
  case $arg in
    --ventoy)
      VENTOY_COPY=true
      ;;
    --vm)
      VM_TEST=true
      ;;
    --no-xattr-warnings|--quiet-xattr)
      SUPPRESS_XATTR_WARNINGS=true
      ;;
    *)
      echo "Usage: $0 [--ventoy] [--vm] [--no-xattr-warnings]"
      echo "  --ventoy  Auto-copy ISO to Ventoy USB drive"
      echo "  --vm      Launch ISO in QEMU VM for testing"
      echo "  --no-xattr-warnings  Hide harmless lgetxattr/read_attrs warnings from build logs"
      exit 1
      ;;
  esac
done

echo "Building easyos ISO with Docker..."
echo "==================================="
echo ""

# Check if we're in the right directory
if [ ! -f "flake.nix" ]; then
  echo "ERROR: Run this script from the easyos repo root" >&2
  exit 1
fi

# Detect Docker or Podman
if command -v docker &> /dev/null; then
  DOCKER_CMD="docker"
elif command -v podman &> /dev/null; then
  DOCKER_CMD="podman"
else
  echo "ERROR: Neither docker nor podman found. Please install one." >&2
  exit 1
fi

echo "Using: $DOCKER_CMD"
echo ""

# Pull the image if needed
if ! $DOCKER_CMD images nixos/nix:latest | grep -q nixos; then
  echo "Pulling nixos/nix:latest..."
  $DOCKER_CMD pull nixos/nix:latest
fi

# Build the ISO
echo "Building ISO (this may take 10-20 minutes on first run)..."
echo ""

# Create output directory
mkdir -p iso-output

$DOCKER_CMD run --rm -it \
  -v "$(pwd):/workspace:Z" \
  -w /workspace \
  -e SUPPRESS_XATTR_WARNINGS=${SUPPRESS_XATTR_WARNINGS} \
  nixos/nix:latest \
  bash -c '
    mkdir -p /root/.config/nix
    echo "experimental-features = nix-command flakes" > /root/.config/nix/nix.conf
    git config --global --add safe.directory /workspace
    export GIT_TERMINAL_PROMPT=0
    
    # Internet check and optional flake update
    echo "Checking internet connectivity for flake updates..."
    if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
      echo "Online. Updating flake inputs from GitHub..."
      set +e
      nix flake update --commit-lock-file
      UPDATE_EXIT=$?
      set -e
      if [ $UPDATE_EXIT -ne 0 ]; then
        echo "⚠ Flake update failed or timed out; proceeding with local flake.lock (may be outdated)."
      fi
    else
      echo "⚠ No internet/DNS unreachable. Using local flake.lock; results may be outdated."
    fi
    
    # Build the ISO
    if [ "${SUPPRESS_XATTR_WARNINGS}" = "true" ]; then
      echo "(suppressing xattr warnings in build logs)"
      set -o pipefail
      nix build .#nixosConfigurations.iso.config.system.build.isoImage --impure --print-build-logs 2>&1 \
        | grep -Evi "lgetxattr failed|read_attrs.*Operation not supported|Operation not supported.*Ignoring"
      BUILD_STATUS=${PIPESTATUS[0]}
      if [ $BUILD_STATUS -ne 0 ]; then
        exit $BUILD_STATUS
      fi
    else
      nix build .#nixosConfigurations.iso.config.system.build.isoImage --impure --print-build-logs
    fi
    
    # Find and copy the ISO to workspace
    ISO_PATH=$(find result/iso -name "*.iso" -type f 2>/dev/null | head -1)
    if [ -n "$ISO_PATH" ]; then
      echo ""
      echo "Copying ISO to workspace..."
      cp -v "$ISO_PATH" /workspace/iso-output/
      echo "ISO copied to iso-output/"
    else
      echo "ERROR: Could not find ISO file" >&2
      exit 1
    fi
  '

BUILD_EXIT=$?
echo ""

if [ $BUILD_EXIT -eq 0 ]; then
  # ISO should now be in iso-output/
  ISO=$(find iso-output -name "*.iso" -type f 2>/dev/null | head -1)
  
  if [ -n "$ISO" ]; then
    SIZE=$(du -h "$ISO" | cut -f1)
    echo ""
    echo "✓ ISO built successfully!"
    echo "  Location: $ISO"
    echo "  Size: $SIZE"
    echo ""
    
    # Ventoy auto-copy
    if [ "$VENTOY_COPY" = true ]; then
      echo "Searching for Ventoy USB drives..."
      VENTOY_MOUNT=""
      
      # Get all mount points and check each one
      while IFS= read -r mount_point; do
        # Skip if empty or doesn't exist
        [ -z "$mount_point" ] && continue
        [ ! -d "$mount_point" ] && continue
        
        # Check if mount point or parent directory contains "Ventoy" (case-insensitive)
        basename_lower=$(basename "$mount_point" | tr '[:upper:]' '[:lower:]')
        if [[ "$basename_lower" == *"ventoy"* ]] || [ -d "$mount_point/ventoy" ] || [ -d "$mount_point/Ventoy" ]; then
          VENTOY_MOUNT="$mount_point"
          break
        fi
      done < <(
        # Collect all possible mount points
        {
          mount | grep -E '^/dev/' | awk '{print $3}'  # All mounted filesystems
          find /run/media -mindepth 2 -maxdepth 2 -type d 2>/dev/null  # User media mounts
          find /media -mindepth 1 -maxdepth 2 -type d 2>/dev/null      # Media directory
          find /mnt -mindepth 1 -maxdepth 1 -type d 2>/dev/null        # /mnt mounts
        } | sort -u
      )
      
      if [ -n "$VENTOY_MOUNT" ]; then
        ISO_NAME="easyos-$(date +%Y%m%d-%H%M).iso"
        DEST_FILE="$VENTOY_MOUNT/$ISO_NAME"
        
        echo "Found Ventoy at: $VENTOY_MOUNT"
        echo "Copying ISO to: $DEST_FILE"
        
        # Copy from wherever the ISO actually is
        if cp -v "$ISO" "$DEST_FILE" 2>/dev/null; then
          sync
          echo ""
          echo "✓ ISO copied to Ventoy USB!"
          echo "  Location: $DEST_FILE"
          echo "  You can now safely eject the USB and boot from it."
          echo ""
        else
          echo "⚠ Failed to copy ISO (permission denied?)"
          echo "  Try: sudo cp \"$ISO\" \"$DEST_FILE\""
          exit 1
        fi
      else
        echo "⚠ No Ventoy USB drive detected."
        echo "  Checked all mounted filesystems for 'Ventoy' in path or ventoy/Ventoy subdirectory"
        echo "  The ISO is available at: $ISO"
        echo ""
        echo "  Manual copy: cp \"$ISO\" /path/to/ventoy/ISOs/"
        echo ""
      fi
    fi
    
    echo "Next steps:"
    if [ "$VENTOY_COPY" = false ]; then
      echo "  1. Copy to Ventoy USB:"
      echo "     cp $ISO /run/media/\$USER/Ventoy/"
      echo ""
      echo "  2. Or write to USB:"
      echo "     sudo dd if=$ISO of=/dev/sdX bs=4M status=progress oflag=sync conv=fsync"
      echo ""
      echo "  3. Or test in VM:"
    else
      echo "  1. Eject Ventoy USB and boot from it"
      echo ""
      echo "  2. Or test in VM first:"
    fi
    echo "     $0 --vm"
    echo ""
    echo "  Inside the booted ISO, run: sudo /etc/easyos-install.sh"
  else
    echo "ERROR: ISO file not found in iso-output/" >&2
    exit 1
  fi
else
  echo "ERROR: ISO build failed" >&2
  exit 1
fi

# Launch VM if requested
if [ "$VM_TEST" = true ]; then
  if [ -z "${ISO:-}" ]; then
    ISO=$(find iso-output -name "*.iso" -type f 2>/dev/null | head -1)
  fi
  
  if [ -z "$ISO" ]; then
    echo "ERROR: No ISO found to test. Build first without --vm flag." >&2
    exit 1
  fi
  
  VM_DISK="/tmp/easyos-test.img"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║                   Launching QEMU VM                            ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Creating test disk: $VM_DISK"
  qemu-img create -f qcow2 "$VM_DISK" 20G
  
  echo ""
  echo "Starting VM with:"
  echo "  ISO: $ISO"
  echo "  RAM: 4GB"
  echo "  Disk: $VM_DISK"
  echo ""
  echo "Press Ctrl+Alt+G to release mouse cursor"
  echo "To exit: Close window or press Ctrl+C in terminal"
  echo ""
  sleep 2
  
  qemu-system-x86_64 \
    -cdrom "$ISO" \
    -m 4096 \
    -enable-kvm \
    -drive file="$VM_DISK",format=qcow2,if=virtio \
    -cpu host \
    -smp 2 \
    -boot d
    
  echo ""
  echo "VM closed. Test disk remains at: $VM_DISK"
  echo "To restart VM: qemu-system-x86_64 -drive file=$VM_DISK,format=qcow2,if=virtio -m 4096 -enable-kvm -cpu host"
fi
 
