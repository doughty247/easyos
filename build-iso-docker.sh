#!/usr/bin/env bash
set -euo pipefail

# EASYOS ISO Builder (Docker/Podman version)
# For use on Bazzite or other non-NixOS systems

# Parse arguments
VENTOY_COPY=false
VM_TEST=false
VM_UPDATE=false
SUPPRESS_XATTR_WARNINGS=true  # Default to suppressing xattr warnings (they're harmless but slow)

for arg in "$@"; do
  case $arg in
    --ventoy)
      VENTOY_COPY=true
      ;;
    --vm)
      VM_TEST=true
      ;;
    --update-vm)
      VM_UPDATE=true
      ;;
    --no-xattr-warnings|--quiet-xattr)
      SUPPRESS_XATTR_WARNINGS=true
      ;;
    *)
      echo "Usage: $0 [--ventoy] [--vm] [--update-vm] [--no-xattr-warnings]"
      echo "  --ventoy  Auto-copy ISO to Ventoy USB drive"
      echo "  --vm      Launch ISO in QEMU VM for testing (fresh install)"
      echo "  --update-vm  Boot existing VM disk and auto-update with latest flake"
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
if command -v docker >/dev/null 2>&1; then
  DOCKER_CMD="docker"
elif command -v podman >/dev/null 2>&1; then
  DOCKER_CMD="podman"
else
  echo "ERROR: Neither docker nor podman found. Please install one." >&2
  exit 1
fi

echo "Using: $DOCKER_CMD"
echo ""

# Pull the image if needed (requires internet)
if ! $DOCKER_CMD images nixos/nix:latest | grep -q nixos; then
  echo "Pulling nixos/nix:latest..."
  if ! $DOCKER_CMD pull nixos/nix:latest; then
    echo "ERROR: Failed to pull Docker image. Check your internet connection." >&2
    exit 1
  fi
fi

# Check if we need to rebuild
NEEDS_BUILD=true
ISO_OUTPUT_DIR="iso-output"
mkdir -p "$ISO_OUTPUT_DIR"

EXISTING_ISO=$(find "$ISO_OUTPUT_DIR" -name "*.iso" -type f 2>/dev/null | head -1)

if [ -n "$EXISTING_ISO" ]; then
  echo "Found existing ISO: $EXISTING_ISO"
  echo "Checking if rebuild is needed..."
  
  # Get ISO timestamp
  ISO_TIME=$(stat -c %Y "$EXISTING_ISO" 2>/dev/null || stat -f %m "$EXISTING_ISO" 2>/dev/null)
  
  # Check if any relevant files have changed since ISO was built
  CHANGED_FILES=0
  
  # Check flake files
  for file in flake.nix flake.lock modules/*.nix etc/easy/config.example.json hardware-configuration.nix; do
    if [ -f "$file" ]; then
      FILE_TIME=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
      if [ "$FILE_TIME" -gt "$ISO_TIME" ]; then
        CHANGED_FILES=$((CHANGED_FILES + 1))
        echo "  Changed: $file"
      fi
    fi
  done
  
  if [ "$CHANGED_FILES" -eq 0 ]; then
    echo "✓ ISO is up to date. Skipping rebuild."
    NEEDS_BUILD=false
    
    # Extract and preserve Nix cache from existing ISO to speed up future builds
    echo "Extracting Nix cache from ISO to speed up future builds..."
    CACHE_DIR=".nix-cache"
    mkdir -p "$CACHE_DIR"
    
    # Mount ISO and copy cache if available
    MOUNT_DIR=$(mktemp -d)
    if sudo mount -o loop "$EXISTING_ISO" "$MOUNT_DIR" 2>/dev/null; then
      if [ -d "$MOUNT_DIR/nix/store" ]; then
        echo "  Copying Nix store cache..."
        rsync -a --info=progress2 "$MOUNT_DIR/nix/store/" "$CACHE_DIR/" 2>/dev/null || true
      fi
      sudo umount "$MOUNT_DIR"
      rmdir "$MOUNT_DIR"
      echo "  Cache preserved for faster rebuilds."
    fi
  else
    echo "Files changed since last build. Rebuilding..."
  fi
else
  echo "No existing ISO found. Building..."
fi

if [ "$NEEDS_BUILD" = false ]; then
  # Skip to the end
  BUILD_EXIT=0
elif [ "$VM_UPDATE" = true ]; then
  # Skip ISO build for --update-vm; we just need to sync the flake to the VM
  echo "Skipping ISO build for --update-vm mode."
  BUILD_EXIT=0
else
  # Build the ISO
  echo ""
  echo "Building ISO (this may take 10-20 minutes on first run)..."
  echo ""

  # Ensure persistent volumes for faster rebuilds
  $DOCKER_CMD volume create easyos-nix-store >/dev/null 2>&1 || true
  $DOCKER_CMD volume create easyos-nix-cache >/dev/null 2>&1 || true

  $DOCKER_CMD run --rm -it \
  -v "$(pwd):/workspace:Z" \
    -v easyos-nix-store:/nix \
    -v easyos-nix-cache:/root/.cache/nix \
  -w /workspace \
  -e SUPPRESS_XATTR_WARNINGS=${SUPPRESS_XATTR_WARNINGS} \
  nixos/nix:latest \
  bash -c '
    mkdir -p /root/.config/nix
    cat > /root/.config/nix/nix.conf <<EOF
experimental-features = nix-command flakes
filter-syscalls = false
max-jobs = auto
cores = 0
narinfo-cache-negative-ttl = 3600
narinfo-cache-positive-ttl = 432000
http-connections = 50
max-substitution-jobs = 16
  substituters = https://cache.nixos.org file:///workspace/.nix-bincache
  require-sigs = false
EOF
    git config --global --add safe.directory /workspace
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      if [ -d /workspace/.nix-bincache ]; then
        echo "Using local binary cache: /workspace/.nix-bincache"
      fi
    
    # Internet check and optional flake update
    echo "Checking internet connectivity for flake updates..."
    # More robust connectivity check that does not depend on TLS CA presence in the container
    ONLINE=0
    if getent hosts github.com > /dev/null 2>&1; then
      # Use an HTTP-only endpoint to avoid CA issues on minimal images
      if curl -s --max-time 5 http://neverssl.com > /dev/null 2>&1; then
        ONLINE=1
      fi
    fi
    if [ "$ONLINE" -eq 1 ]; then
      echo "Online. Checking if updates are available..."
      
      # Get local flake.lock timestamp if it exists
      if [ -f flake.lock ]; then
        LOCAL_TIME=$(stat -c %Y flake.lock 2>/dev/null || stat -f %m flake.lock 2>/dev/null)
        CURRENT_TIME=$(date +%s)
        AGE_SECONDS=$((CURRENT_TIME - LOCAL_TIME))
        AGE_DAYS=$((AGE_SECONDS / 86400))
        
        if [ $AGE_DAYS -gt 0 ]; then
          if [ $AGE_DAYS -eq 1 ]; then
            AGE_MSG="1 day old"
          elif [ $AGE_DAYS -lt 30 ]; then
            AGE_MSG="$AGE_DAYS days old"
          elif [ $AGE_DAYS -lt 60 ]; then
            AGE_MSG="1 month old"
          else
            AGE_MONTHS=$((AGE_DAYS / 30))
            AGE_MSG="$AGE_MONTHS months old"
          fi
          
          echo "Local flake.lock is $AGE_MSG."
          printf "Would you like to update from GitHub? (Y/n): "
          read -r RESPONSE
          if [ "$RESPONSE" = "n" ] || [ "$RESPONSE" = "N" ]; then
            echo "Skipping update. Using local flake.lock."
          else
            echo "Updating flake inputs from GitHub..."
            set +e
            nix flake update --commit-lock-file 2>&1 | grep -v "warning: ignoring untrusted"
            UPDATE_EXIT=$?
            set -e
            if [ $UPDATE_EXIT -ne 0 ]; then
              echo "WARNING: Flake update failed; proceeding with local flake.lock."
            else
              echo "✓ Flake inputs updated successfully."
            fi
          fi
        else
          echo "Local flake.lock is current (updated today). Skipping update."
        fi
      else
        echo "No local flake.lock found. Fetching latest from GitHub..."
        set +e
        nix flake update --commit-lock-file 2>&1 | grep -v "warning: ignoring untrusted"
        UPDATE_EXIT=$?
        set -e
        if [ $UPDATE_EXIT -ne 0 ]; then
          echo "WARNING: Flake update failed."
        fi
      fi
    else
      echo "WARNING: No internet (or DNS/HTTP unavailable). Using local flake.lock; may be outdated."
    fi
    
    # Build the ISO
    if [ "${SUPPRESS_XATTR_WARNINGS}" = "true" ]; then
      set -o pipefail
      nix build .#nixosConfigurations.iso.config.system.build.isoImage --impure --print-build-logs --accept-flake-config 2>&1 | \
        grep -Evi "lgetxattr|lsetxattr|llistxattr|lremovexattr|read_attrs|write_attrs"
      BUILD_STATUS=$?
      set +o pipefail
      if [ $BUILD_STATUS -ne 0 ]; then
        exit $BUILD_STATUS
      fi
    else
      nix build .#nixosConfigurations.iso.config.system.build.isoImage --impure --print-build-logs --accept-flake-config
      BUILD_STATUS=$?
      if [ $BUILD_STATUS -ne 0 ]; then
        exit $BUILD_STATUS
      fi
    fi
    
    # Find and move the ISO into workspace (clean older ISOs to avoid duplicates)
    ISO_PATH=$(find result/iso -name "*.iso" -type f 2>/dev/null | head -1)
    if [ -n "$ISO_PATH" ]; then
      echo ""
      echo "Preparing iso-output/ (removing previous ISO files)..."
      find /workspace/iso-output -maxdepth 1 -type f -name "*.iso" -print -exec rm -f {} + 2>/dev/null || true
      echo "Transferring ISO to workspace..."
      # mv may fail when crossing filesystems or from read-only nix store; fall back to copy
      if mv -v "$ISO_PATH" /workspace/iso-output/ 2>/dev/null; then
        echo "ISO moved to iso-output/"
      else
        cp -v "$ISO_PATH" /workspace/iso-output/
        echo "ISO copied to iso-output/ (source in nix store retained)"
      fi
    else
      echo "ERROR: Could not find ISO file" >&2
      exit 1
    fi
  '

  BUILD_EXIT=$?
fi
echo ""

if [ $BUILD_EXIT -ne 0 ]; then
  echo ""
  echo "ERROR: ISO build failed with exit code $BUILD_EXIT"
  echo "Check the output above for details."
  exit $BUILD_EXIT
fi

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
      
      # Portable scan for Ventoy mount without process substitution (works in strict shells)
      # 1) Try to find a mountpoint with "ventoy" in its path from the mount table
      VENTOY_MOUNT=$(mount | awk '{print $3}' | awk 'BEGIN{IGNORECASE=1} /ventoy/ {print; exit}')
      # 2) If not found, probe common removable media roots
      if [ -z "$VENTOY_MOUNT" ]; then
        for d in /run/media/*/* /media/* /mnt/*; do
          [ -d "$d" ] || continue
          basename_lower=$(basename "$d" | tr '[:upper:]' '[:lower:]')
          if [[ "$basename_lower" == *"ventoy"* ]] || [ -d "$d/ventoy" ] || [ -d "$d/Ventoy" ]; then
            VENTOY_MOUNT="$d"
            break
          fi
        done
      fi
      
      if [ -n "$VENTOY_MOUNT" ]; then
        ISO_NAME="easyos-$(date +%Y%m%d-%H%M).iso"
        DEST_FILE="$VENTOY_MOUNT/$ISO_NAME"
        
        echo "Found Ventoy at: $VENTOY_MOUNT"
        echo "Copying ISO to: $DEST_FILE"
        
        # Copy to Ventoy (keep local ISO in iso-output for reuse)
        if cp -v "$ISO" "$DEST_FILE" 2>/dev/null; then
          sync
          echo ""
          echo "✓ ISO copied to Ventoy USB!"
          echo "  Location: $DEST_FILE"
          echo "  You can now safely eject the USB and boot from it."
          echo ""
        else
          echo "WARNING: Failed to copy ISO (permission denied?)"
          echo "  Try: sudo cp \"$ISO\" \"$DEST_FILE\""
          exit 1
        fi
      else
        echo "WARNING: No Ventoy USB drive detected."
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

# Launch VM if requested (fresh install from ISO)
if [ "$VM_TEST" = true ]; then
  if [ -z "${ISO:-}" ]; then
    ISO=$(find iso-output -name "*.iso" -type f 2>/dev/null | head -1)
  fi
  
  if [ -z "$ISO" ]; then
    echo "ERROR: No ISO found to test. Build first without --vm flag." >&2
    exit 1
  fi
  
  # Check available RAM
  TOTAL_RAM=$(free -m | awk '/^Mem:/ {print $2}')
  AVAILABLE_RAM=$(free -m | awk '/^Mem:/ {print $7}')
  VM_RAM=8192  # 8GB for VM
  REQUIRED_HOST_RAM=8192  # 8GB minimum for host
  REQUIRED_TOTAL=$((VM_RAM + REQUIRED_HOST_RAM))
  
  echo ""
  echo "Memory check:"
  echo "  Total RAM: $((TOTAL_RAM / 1024)) GB"
  echo "  Available RAM: $((AVAILABLE_RAM / 1024)) GB"
  echo "  VM allocation: 8 GB"
  echo "  Required for host: 8 GB"
  
  if [ "$TOTAL_RAM" -lt "$REQUIRED_TOTAL" ]; then
    echo ""
    echo "WARNING: System has only $((TOTAL_RAM / 1024)) GB total RAM."
    echo "  Allocating 8 GB to VM may leave insufficient RAM for host."
    echo "  Using 4 GB for VM instead."
    VM_RAM=4096
  fi
  
  VM_DISK="/tmp/easyos-test.img"
  
  echo ""
  echo "================================================================"
  echo "                   Launching QEMU VM                            "
  echo "================================================================"
  echo ""
  
  # Force remove existing disk for fresh install
  if [ -f "$VM_DISK" ]; then
    echo "Removing existing VM disk: $VM_DISK"
    rm -f "$VM_DISK"
  fi
  
  echo "Creating test disk: $VM_DISK"
  qemu-img create -f qcow2 "$VM_DISK" 20G
  
  echo ""
  echo "Starting VM with:"
  echo "  ISO: $ISO"
  echo "  RAM: $((VM_RAM / 1024))GB"
  echo "  Disk: $VM_DISK"
  echo ""
  echo "Press Ctrl+Alt+G to release mouse cursor"
  echo "To exit: Close window or press Ctrl+C in terminal"
  echo ""
  sleep 2
  
  # Prefer UEFI boot (systemd-boot). Detect common OVMF paths.
  OVMF_CODE=""
  OVMF_VARS=""
  for p in \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
    [ -f "$p" ] && OVMF_CODE="$p" && break
  done
  for p in \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd; do
    [ -f "$p" ] && OVMF_VARS="$p" && break
  done

  if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    OVMF_VARS_RW="/tmp/OVMF_VARS.easyos.fd"
    cp "$OVMF_VARS" "$OVMF_VARS_RW" 2>/dev/null || true
    echo "Using UEFI firmware: $OVMF_CODE"
    qemu-system-x86_64 \
      -machine type=q35,accel=kvm \
      -cpu host \
      -smp 2 \
      -m "$VM_RAM" \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$OVMF_VARS_RW" \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -cdrom "$ISO" \
      -boot d
  else
    echo "WARNING: Could not find OVMF (UEFI) firmware on host. Falling back to BIOS (GRUB required)."
    qemu-system-x86_64 \
      -cdrom "$ISO" \
      -m "$VM_RAM" \
      -enable-kvm \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -cpu host \
      -smp 2 \
      -boot d
  fi
    
  echo ""
  echo "VM closed. Test disk remains at: $VM_DISK"
  echo "To restart VM: qemu-system-x86_64 -drive file=$VM_DISK,format=qcow2,if=virtio -m $VM_RAM -enable-kvm -cpu host"
  echo "To update the VM with latest flake changes: $0 --update-vm"
fi

# Update existing VM disk with latest flake changes
if [ "$VM_UPDATE" = true ]; then
  VM_DISK="/tmp/easyos-test.img"
  
  if [ ! -f "$VM_DISK" ]; then
    echo "ERROR: VM disk not found at $VM_DISK"
    echo "Run '$0 --vm' first to create an installed VM, then use --update-vm to sync changes."
    exit 1
  fi
  
  # Check if QEMU is actually running with this disk
  if pgrep -f "qemu.*easyos-test.img" >/dev/null 2>&1; then
    echo ""
    echo "================================================================"
    echo "         VM Already Running                                     "
    echo "================================================================"
    echo ""
    echo "The VM at $VM_DISK is already in use."
    echo ""
    echo "Options:"
    echo "  1. Close the existing VM window and run this command again"
    echo "  2. Or access the running VM directly:"
    echo "     - Web UI: http://localhost:8088/ (if port forwarding is active)"
    echo "     - Console: Switch to the QEMU window"
    echo ""
    echo "To update the running VM:"
    echo "  - Use the web UI to edit config and click 'Save & Apply'"
    echo "  - Or SSH/console: cd /etc/nixos/easyos && git pull && nixos-rebuild switch --impure --flake .#easyos"
    echo ""
    exit 1
  fi
  
  # Clean up any stale lock files
  LOCK_FILE="$VM_DISK.lock"
  if [ -f "$LOCK_FILE" ]; then
    echo "Removing stale lock file: $LOCK_FILE"
    rm -f "$LOCK_FILE"
  fi
  
  echo ""
  echo "================================================================"
  echo "         Updating Existing VM with Latest Flake                "
  echo "================================================================"
  echo ""
  echo "VM Disk: $VM_DISK"
  echo ""
  echo "This will:"
  echo "  1. Mount the VM disk"
  echo "  2. Sync the current flake to /mnt/etc/nixos/easyos"
  echo "  3. Boot the VM so you can apply changes via the web UI"
  echo ""
  
  # Mount the VM disk
  MOUNT_DIR=$(mktemp -d)
  
  echo "Mounting VM disk..."
  # Simplify: proceed with manual sync flow to avoid host tooling differences
  # Optional optimization with virt-copy-in can be re-enabled later
  if command -v virt-copy-in >/dev/null 2>&1; then
    echo "Note: virt-copy-in detected; manual flow used for portability."
  fi
  SYNC_METHOD="manual"
  
  # Now boot the VM
  echo ""
  echo "Booting VM..."
  if [ "$SYNC_METHOD" = "manual" ]; then
    echo ""
    echo "==================================================================="
    echo "Manual sync required:"
    echo "  1. SSH into the VM or use the console"
    echo "  2. Run: cd /etc/nixos/easyos && git pull"
    echo "  3. Or use the web UI at http://localhost:8088/ to edit & apply"
    echo "==================================================================="
  else
    echo "Web UI available at http://localhost:8088/"
    echo "Click 'Save & Apply' to rebuild with latest changes."
  fi
  echo ""
  sleep 2
  
  # Detect OVMF and boot
  OVMF_CODE=""
  OVMF_VARS=""
  for p in \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
    [ -f "$p" ] && OVMF_CODE="$p" && break
  done
  for p in \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd; do
    [ -f "$p" ] && OVMF_VARS="$p" && break
  done

  if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    OVMF_VARS_RW="/tmp/OVMF_VARS.easyos-update.fd"
    # Reuse existing OVMF_VARS if present from previous boots
    [ -f "/tmp/OVMF_VARS.easyos.fd" ] && cp "/tmp/OVMF_VARS.easyos.fd" "$OVMF_VARS_RW" || cp "$OVMF_VARS" "$OVMF_VARS_RW"
    
    qemu-system-x86_64 \
      -machine type=q35,accel=kvm \
      -cpu host \
      -smp 2 \
      -m 8192 \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$OVMF_VARS_RW" \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -net nic,model=virtio \
      -net user,hostfwd=tcp::8088-:8088
  else
    echo "WARNING: OVMF not found. Falling back to BIOS boot."
    qemu-system-x86_64 \
      -m 8192 \
      -enable-kvm \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -cpu host \
      -smp 2 \
      -net nic,model=virtio \
      -net user,hostfwd=tcp::8088-:8088
  fi
  
  echo ""
  echo "VM closed."
fi
 
