#!/usr/bin/env bash
set -euo pipefail
# Log everything to a session log for troubleshooting
LOGFILE=/tmp/easyos-install.log
exec > >(tee -a "$LOGFILE") 2>&1

# Use a dedicated TTY file descriptor (fd 3) for prompts so
# logging/tee on stdout/stderr never interferes with input.
TTY_DEV=/dev/tty
if [ -c "$TTY_DEV" ]; then
  # Open a dedicated fd (3) to the controlling TTY for prompts
  exec 3<>"$TTY_DEV" || true
else
  # Fallbacks if /dev/tty unavailable (very rare on live ISO)
  exec 3>&1 || true
fi
cleanup_fds() { exec 3>&- 3<&- 2>/dev/null || true; }
trap cleanup_fds EXIT

prompt() {
  # usage: prompt "Question [default]: " varname [default]
  local _msg="$1"; shift
  local _var="$1"; shift
  local _def="${1:-}"
  local _ans=""
  # Show prompt on TTY if available, otherwise stdout
  if [ -t 3 ]; then
    printf "%s" "${_msg}" >&3 2>/dev/null
    IFS= read -r _ans <&3 || _ans=""
  elif [ -r /dev/tty ]; then
    printf "%s" "${_msg}"
    IFS= read -r _ans </dev/tty || _ans=""
  else
    printf "%s" "${_msg}"
    IFS= read -r _ans || _ans=""
  fi
  if [ -z "${_ans}" ] && [ -n "${_def}" ]; then
    eval "${_var}='${_def}'"
  else
    eval "${_var}='${_ans}'"
  fi
}
prompt_secret() {
  # usage: prompt_secret "Password: " varname
  local _msg="$1"; shift
  local _var="$1"; shift
  local _ans=""
  # Show prompt on TTY if available, otherwise stdout
  if [ -t 3 ]; then
    printf "%s" "${_msg}" >&3 2>/dev/null
    stty -echo <&3 2>/dev/null || true
    IFS= read -r _ans <&3 || _ans=""
    stty echo <&3 2>/dev/null || true
    printf "\n" >&3 2>/dev/null
  elif [ -r /dev/tty ]; then
    printf "%s" "${_msg}"
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r _ans </dev/tty || _ans=""
    stty echo </dev/tty 2>/dev/null || true
    printf "\n"
  else
    # Last resort: read from stdin (may be piped)
    printf "%s" "${_msg}"
    stty -echo 2>/dev/null || true
    IFS= read -r _ans || _ans=""
    stty echo 2>/dev/null || true
    printf "\n"
  fi
  eval "${_var}='${_ans}'"
}

# Reduce kernel messages on the console to avoid noisy interleaving
# that can obscure or interrupt prompts.
(dmesg -n 1 2>/dev/null || true)
if [ -w /proc/sys/kernel/printk ]; then echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null || true; fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This installer must be run as root."
  echo "Please run: sudo easyos-install"
  exit 1
fi

# Minimal self-check: verify heredoc markers exist in this script
validate_heredocs() {
  local self="/etc/easyos-install.sh"
  local openEON closeEON openEOCRED closeEOCRED
  # Use patterns that won't match themselves in the grep search
  openEON=$(grep -Ec "<<'?E""ON'?" "$self" 2>/dev/null || echo 0)
  closeEON=$(grep -Ec "^E""ON\$" "$self" 2>/dev/null || echo 0)
  openEOCRED=$(grep -Ec "<<E""OCRED" "$self" 2>/dev/null || echo 0)
  closeEOCRED=$(grep -Ec "^E""OCRED\$" "$self" 2>/dev/null || echo 0)
  if [ "$openEON" -ne "$closeEON" ] || [ "$openEOCRED" -ne "$closeEOCRED" ]; then
    echo "ERROR: Installer script appears malformed (heredoc markers mismatch)."
    echo "Please rebuild the ISO and try again."
    exit 1
  fi
}
validate_heredocs

# Check network connectivity - already done by ISO boot, just verify
echo "Checking network connectivity..."
if ! curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
  echo ""
  echo "⚠ No internet connection detected."
  echo ""
  echo "Opening network configuration..."
  sleep 1

  nmtui

  # Check again
  echo ""
  echo "Re-checking connectivity..."
  if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
    echo "✓ Internet connection established!"
  else
    echo ""
    echo "⚠ Still no internet connection."
    echo "Installation requires internet access to download packages."
    echo "You can run 'sudo nmtui' to configure network, or continue anyway."
    echo ""
    prompt "Continue with installation? (y/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 0
    fi
  fi
else
  echo "✓ Internet connection detected."
fi

clear
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                      EASYOS Installer                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "This installer will:"
echo "  • Partition and format the target drive (ALL DATA WILL BE LOST)"
echo "  • Install NixOS with the easyos configuration"
echo "  • Set up Btrfs with compression and subvolumes"
echo "  • Clone the easyos flake from GitHub"
echo ""

# List available block devices
echo "Available drives:"
echo "────────────────────────────────────────────────────────────────"
lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
echo ""

# Get target device
while true; do
  prompt "Target device (e.g., /dev/sda or /dev/nvme0n1): " DEVICE

  if [ ! -b "$DEVICE" ]; then
    echo "⚠ ERROR: $DEVICE is not a valid block device"
    continue
  fi

  # Show what's on the device
  echo ""
  echo "Current partitions on $DEVICE:"
  lsblk "$DEVICE" || true
  echo ""

  # Final confirmation with explicit warning
  echo "⚠⚠⚠  WARNING  ⚠⚠⚠"
  echo "This will COMPLETELY ERASE $DEVICE and ALL its data!"
  echo "This action CANNOT be undone."
  echo ""
  prompt "Type 'YES' in all caps to confirm: " CONFIRM

  if [ "$CONFIRM" = "YES" ]; then
    break
  else
    echo "Installation cancelled."
    exit 1
  fi
done

# Get hostname
prompt "Hostname for this system [easyos]: " HOSTNAME
HOSTNAME=${HOSTNAME:-easyos}

# Get admin username
prompt "Admin username [easyadmin]: " ADMIN
ADMIN=${ADMIN:-easyadmin}

# Get admin password (with confirmation)
while true; do
  prompt_secret "Admin password: " ADMIN_PASS
  prompt_secret "Confirm admin password: " ADMIN_PASS2
  if [ "${ADMIN_PASS}" != "${ADMIN_PASS2}" ]; then
    echo "Passwords do not match. Please try again."
  elif [ -z "${ADMIN_PASS}" ]; then
    echo "Password cannot be empty. Please try again."
  else
    break
  fi
done

# Root password choice
prompt "Use the same password for root? [Y/n]: " SAME_ROOT
SAME_ROOT=${SAME_ROOT:-Y}
if [[ "$SAME_ROOT" =~ ^[Nn]$ ]]; then
  while true; do
    prompt_secret "Root password: " ROOT_PASS
    prompt_secret "Confirm root password: " ROOT_PASS2
    if [ "${ROOT_PASS}" != "${ROOT_PASS2}" ]; then
      echo "Passwords do not match. Please try again."
    elif [ -z "${ROOT_PASS}" ]; then
      echo "Password cannot be empty. Please try again."
    else
      break
    fi
  done
else
  ROOT_PASS="${ADMIN_PASS}"
fi

# Hash passwords using SHA-512
ADMIN_HASH=$(openssl passwd -6 "${ADMIN_PASS}")
ROOT_HASH=$(openssl passwd -6 "${ROOT_PASS}")
# Safety net to avoid post-install lockout
if [ -z "${ADMIN_HASH}" ] || [ -z "${ROOT_HASH}" ]; then
  echo "WARNING: Password hashing failed; defaulting admin/root password to 'easyos'."
  ADMIN_HASH=$(openssl passwd -6 "easyos")
  ROOT_HASH="$ADMIN_HASH"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Installation Summary:"
echo "  Target: $DEVICE"
echo "  Hostname: $HOSTNAME"
echo "  Admin user: $ADMIN"
echo "══════════════════════════════════════════════════════════════"
echo ""
prompt "Press ENTER to begin installation or Ctrl+C to cancel..." _

# TPM2 detection and encryption option
ENCRYPT=0
HAS_TPM=0
TPM_DEV=""
if [ -c /dev/tpmrm0 ]; then TPM_DEV="/dev/tpmrm0"; HAS_TPM=1; fi
if [ "$HAS_TPM" -eq 0 ] && [ -c /dev/tpm0 ]; then TPM_DEV="/dev/tpm0"; HAS_TPM=1; fi
if [ "$HAS_TPM" -eq 1 ] && command -v systemd-cryptenroll >/dev/null 2>&1; then
  echo ""
  echo "TPM2 device detected ($TPM_DEV)."
  echo "You can enable disk encryption for the Btrfs data partition and enroll TPM2 for auto-unlock."
  echo "A printed recovery key will be generated as fallback."
  prompt "Enable disk encryption with TPM2 auto-unlock? [y/N]: " ENC_CHOICE
  if [[ "$ENC_CHOICE" =~ ^[Yy]$ ]]; then ENCRYPT=1; fi
else
  echo ""
  echo "No compatible TPM2 device found or systemd-cryptenroll unavailable."
  echo "Proceeding without disk encryption."
fi

echo ""
echo "⚙ Preparing $DEVICE..."
# Unmount any existing partitions on the target device
umount -R "$DEVICE"* 2>/dev/null || true
# Close any LUKS mappings that might be using this device
for mapper in /dev/mapper/*; do
  if [ -L "$mapper" ] && cryptsetup status "$(basename "$mapper")" 2>/dev/null | grep -q "$DEVICE"; then
    cryptsetup close "$(basename "$mapper")" 2>/dev/null || true
  fi
done
# Wipe any existing partition table and filesystem signatures
wipefs -af "$DEVICE" 2>/dev/null || true
dd if=/dev/zero of="$DEVICE" bs=1M count=10 conv=fsync 2>/dev/null || true

echo "⚙ Partitioning $DEVICE..."
if [ -d /sys/firmware/efi ]; then
  echo "  Firmware: UEFI (systemd-boot)"
  parted -s "$DEVICE" -- mklabel gpt
  parted -s "$DEVICE" -- mkpart ESP fat32 1MiB 512MiB
  parted -s "$DEVICE" -- set 1 esp on
  parted -s "$DEVICE" -- mkpart primary btrfs 512MiB 100%

  # Handle both /dev/sdX and /dev/nvmeXnY naming
  if [[ "$DEVICE" =~ "nvme" ]]; then
    BOOT="${DEVICE}p1"
    ROOT="${DEVICE}p2"
  else
    BOOT="${DEVICE}1"
    ROOT="${DEVICE}2"
  fi
  BOOT_MODE="uefi"
else
  echo "  Firmware: BIOS/Legacy (GRUB)"
  parted -s "$DEVICE" -- mklabel gpt
  parted -s "$DEVICE" -- mkpart biosboot 1MiB 2MiB
  parted -s "$DEVICE" -- set 1 bios_grub on
  if [ "$ENCRYPT" -eq 1 ]; then
    # When encrypting root on BIOS, create an unencrypted /boot partition
    parted -s "$DEVICE" -- mkpart boot ext4 2MiB 1026MiB
    parted -s "$DEVICE" -- mkpart primary btrfs 1026MiB 100%
    if [[ "$DEVICE" =~ "nvme" ]]; then
      BOOT="${DEVICE}p2"
      ROOT="${DEVICE}p3"
    else
      BOOT="${DEVICE}2"
      ROOT="${DEVICE}3"
    fi
  else
    parted -s "$DEVICE" -- mkpart primary btrfs 2MiB 100%
    if [[ "$DEVICE" =~ "nvme" ]]; then
      ROOT="${DEVICE}p2"
    else
      ROOT="${DEVICE}2"
    fi
    BOOT="" # no separate /boot
  fi
  BOOT_MODE="bios"
fi

# Force kernel to re-read partition table
partprobe "$DEVICE" 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true
sleep 3  # Give kernel time to recognize new partitions

# Wipe any existing filesystem signatures on the NEW partitions
wipefs -af "$ROOT" 2>/dev/null || true
if [ -n "${BOOT:-}" ]; then
  wipefs -af "$BOOT" 2>/dev/null || true
fi

echo "⚙ Formatting partitions..."
if [ "$BOOT_MODE" = "uefi" ]; then
  mkfs.fat -F 32 -n BOOT "$BOOT"
elif [ "$ENCRYPT" -eq 1 ] && [ -n "${BOOT:-}" ]; then
  mkfs.ext4 -F -L boot "$BOOT"
fi

CRYPT_DEV=""
if [ "$ENCRYPT" -eq 1 ]; then
  echo "  • Setting up LUKS2 on $ROOT with TPM2 auto-unlock (to be enrolled)"
  # Create a temporary passphrase for initial format and enrollment
  TEMP_PASS=$(openssl rand -base64 32)
  # Format LUKS2 container
  echo -n "$TEMP_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id "$ROOT" -
  # Open it as cryptroot
  echo -n "$TEMP_PASS" | cryptsetup open "$ROOT" cryptroot --key-file -
  CRYPT_DEV="/dev/mapper/cryptroot"
  # Create Btrfs on the encrypted device
  mkfs.btrfs -f -L nixos "$CRYPT_DEV"
else
  mkfs.btrfs -f -L nixos "$ROOT"
fi

echo "⚙ Creating btrfs subvolumes..."
if [ "$ENCRYPT" -eq 1 ]; then
  mount "$CRYPT_DEV" /mnt
else
  mount "$ROOT" /mnt
fi
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/nix
btrfs subvolume create /mnt/var
umount /mnt

echo "⚙ Mounting filesystems..."
if [ "$ENCRYPT" -eq 1 ]; then
  mount -o subvol=root,compress=zstd "$CRYPT_DEV" /mnt
else
  mount -o subvol=root,compress=zstd "$ROOT" /mnt
fi
mkdir -p /mnt/{home,nix,var}
[ "$BOOT_MODE" = "uefi" ] && mkdir -p /mnt/boot || true
if [ "$ENCRYPT" -eq 1 ]; then
  mount -o subvol=home,compress=zstd "$CRYPT_DEV" /mnt/home
  mount -o subvol=nix,compress=zstd,noatime "$CRYPT_DEV" /mnt/nix
  mount -o subvol=var,compress=zstd "$CRYPT_DEV" /mnt/var
else
  mount -o subvol=home,compress=zstd "$ROOT" /mnt/home
  mount -o subvol=nix,compress=zstd,noatime "$ROOT" /mnt/nix
  mount -o subvol=var,compress=zstd "$ROOT" /mnt/var
fi
if [ "$BOOT_MODE" = "uefi" ] || { [ "$BOOT_MODE" = "bios" ] && [ -n "${BOOT:-}" ]; }; then
  mount "$BOOT" /mnt/boot
  # Restrict boot partition permissions to fix systemd random seed warnings
  chmod 755 /mnt/boot
fi

# Create systemd random seed directory with proper permissions
mkdir -p /mnt/var/lib/systemd
chmod 755 /mnt/var/lib/systemd

echo "⚙ Creating 8GiB swapfile (with no CoW)..."
# Create swapfile on btrfs correctly: set NOCOW before writing
touch /mnt/swapfile
chattr +C /mnt/swapfile 2>/dev/null || true
fallocate -l 8G /mnt/swapfile 2>/dev/null || dd if=/dev/zero of=/mnt/swapfile bs=1M count=8192
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile

echo "⚙ Generating hardware configuration..."
nixos-generate-config --root /mnt

# If encryption was selected, enroll TPM2 and a recovery key now
if [ "$ENCRYPT" -eq 1 ]; then
  echo "⚙ Enrolling TPM2 auto-unlock and generating recovery key..."
  echo "  Closing encrypted device for enrollment (required by systemd-cryptenroll)..."
  # systemd-cryptenroll requires the LUKS device to be closed for enrollment
  # Ensure nothing is using /mnt
  sync
  # Unmount in reverse order (deepest first)
  umount /mnt/var 2>/dev/null || true
  umount /mnt/nix 2>/dev/null || true
  umount /mnt/home 2>/dev/null || true
  umount /mnt/boot 2>/dev/null || true
  umount /mnt 2>/dev/null || true
  udevadm settle --timeout=5 2>/dev/null || true
  sleep 1
  # Close the encrypted device with retry logic
  CLOSED=0
  for i in $(seq 1 10); do
    if cryptsetup close cryptroot 2>/dev/null; then
      CLOSED=1
      break
    fi
    # If close failed, check what's holding it
    if [ $i -eq 1 ]; then
      echo "  Device busy, identifying processes..."
      lsof 2>/dev/null | grep -i crypt || true
      fuser -v /dev/mapper/cryptroot 2>&1 || true
    fi
    echo "  Waiting for cryptroot to be free... ($i/10)"
    fuser -km /dev/mapper/cryptroot 2>/dev/null || true
    sleep 1
  done
  if [ $CLOSED -eq 0 ]; then
    echo "ERROR: Could not close cryptroot after 10 attempts. Device is held open."
    exit 1
  fi

  # Check for TPM2 support
  echo "  Checking TPM2 hardware..."
  if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
    echo "WARNING: No TPM device found. TPM unlock will not work."
    echo "  Continuing with recovery key only..."
    TPM_AVAILABLE=0
  else
    TPM_AVAILABLE=1
    echo "  TPM device detected: $(ls /dev/tpm* | head -1)"
  fi

  # Enroll TPM2 with device closed (proper production setup)
  if [ $TPM_AVAILABLE -eq 1 ]; then
    echo "  Enrolling TPM2 unlock (PCR 7 - Secure Boot state)..."
    ENROLL_TPM_OUT=$(systemd-cryptenroll "$ROOT" \
      --unlock-key-file=<(printf "%s" "$TEMP_PASS") \
      --tpm2-device=auto \
      --tpm2-pcrs=7 \
      --wipe-slot=tpm2 2>&1) || {
        echo "WARNING: systemd-cryptenroll TPM2 enrollment failed"
        echo "$ENROLL_TPM_OUT"
        echo "  Continuing without TPM unlock (recovery key will be required at boot)..."
        TPM_AVAILABLE=0
      }

    if [ $TPM_AVAILABLE -eq 1 ]; then
      echo "  ✓ TPM2 enrollment successful"
      echo "    Bound to PCR 7 (Secure Boot state)"
      echo "    Your system will auto-unlock if:"
      echo "    - TPM is present"
      echo "    - Secure Boot state unchanged"
      echo "    - UEFI firmware unchanged"
    fi
  fi

  # Add a recovery key as a separate operation (prints key to stdout)
  echo "  Adding recovery key..."
  RECOVERY_OUT=$(systemd-cryptenroll "$ROOT" \
    --unlock-key-file=<(printf "%s" "$TEMP_PASS") \
    --recovery-key 2>&1) || {
      echo "ERROR: systemd-cryptenroll recovery-key enrollment failed"
      echo "$RECOVERY_OUT"
      exit 1
    }

  # Extract the printed recovery key robustly from output
  # systemd-cryptenroll may print different formats across versions:
  #  - 8 groups of 5 digits (classic numeric)
  #  - Alphanumeric groups (letters/digits) separated by dashes
  #  - On some builds, the key is shown on the line after a colon
  RECOVERY_KEY=$(printf "%s\n" "$RECOVERY_OUT" \
    | tr -d '\r' \
    | grep -Eo '([A-Za-z0-9]{4,}-){3,}[A-Za-z0-9]{4,}|([0-9]{5}-){7}[0-9]{5}' \
    | head -1 || true)
  if [ -z "$RECOVERY_KEY" ]; then
    # Fallback: take the first non-empty line following the colon on the
    # "secret recovery key" message block
    RECOVERY_KEY=$(printf "%s\n" "$RECOVERY_OUT" \
      | tr -d '\r' \
      | sed -n '/secret recovery key/,$p' \
      | sed -n '2{/^\s*$/d; s/^\s*//; p; q}')
  fi
  if [ -z "$RECOVERY_KEY" ]; then
    echo "$RECOVERY_OUT"
    echo "WARNING: Could not parse recovery key from systemd-cryptenroll output."
    echo "         Keeping temporary passphrase to avoid lockout."
    # Reopen using temporary passphrase to proceed
    echo -n "$TEMP_PASS" | cryptsetup open "$ROOT" cryptroot --key-file -
    CRYPT_DEV="/dev/mapper/cryptroot"
    # Persist full output for later retrieval
    mkdir -p /mnt/etc/easy
    printf "%s\n" "$RECOVERY_OUT" > /mnt/etc/easy/recovery-output.txt 2>/dev/null || true
  else
    # Validate the recovery key before removing the temporary passphrase
    echo "  Validating recovery key by opening the LUKS device..."
    if echo -n "$RECOVERY_KEY" | cryptsetup open "$ROOT" cryptroot --key-file -; then
      CRYPT_DEV="/dev/mapper/cryptroot"
      echo "  Recovery key validated. Removing temporary passphrase..."
      echo -n "$TEMP_PASS" | cryptsetup luksRemoveKey "$ROOT" - || true
    else
      echo "WARNING: Unlock with recovery key failed."
      echo "         Keeping temporary passphrase to avoid lockout."
      echo -n "$TEMP_PASS" | cryptsetup open "$ROOT" cryptroot --key-file -
      CRYPT_DEV="/dev/mapper/cryptroot"
    fi
  fi

  # Remount all subvolumes for installation
  mount -o subvol=root,compress=zstd "$CRYPT_DEV" /mnt
  mkdir -p /mnt/{home,nix,var,boot}
  mount -o subvol=home,compress=zstd "$CRYPT_DEV" /mnt/home
  mount -o subvol=nix,compress=zstd,noatime "$CRYPT_DEV" /mnt/nix
  mount -o subvol=var,compress=zstd "$CRYPT_DEV" /mnt/var
  if [ "$BOOT_MODE" = "uefi" ] || [ -n "${BOOT:-}" ]; then
    mount "$BOOT" /mnt/boot
  fi
  
  # Persist recovery key or output for troubleshooting
  mkdir -p /mnt/etc/easy
  if [ -n "$RECOVERY_KEY" ]; then
    printf "%s\n" "$RECOVERY_KEY" > /mnt/etc/easy/recovery.key
    chmod 600 /mnt/etc/easy/recovery.key
    echo "  Recovery key saved to /etc/easy/recovery.key on the installed system."
  else
    # Leave recovery-output.txt written above for analysis
    echo "  NOTE: Recovery key parse failed; full enroll output saved to /etc/easy/recovery-output.txt"
  fi
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "RECOVERY KEY - Scan this QR code or write it down:"
  echo ""
  if [ -n "$RECOVERY_KEY" ]; then
    echo "  $RECOVERY_KEY"
  else
    echo "  (not parsed; see /etc/easy/recovery-output.txt)"
  fi
  echo ""
  # Display QR code for easy scanning with phone
  if command -v qrencode >/dev/null 2>&1 && [ -n "$RECOVERY_KEY" ]; then
    qrencode -t ANSIUTF8 -m 2 "$RECOVERY_KEY" || qrencode -t UTF8 -m 2 "$RECOVERY_KEY" || true
  fi
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo ""
  prompt "Press ENTER after saving the recovery key to continue..." _
  echo ""
  
  # Prepare easy-encryption.nix for TPM auto-unlock
  LUKS_UUID=$(cryptsetup luksUUID "$ROOT")
  if [ $TPM_AVAILABLE -eq 1 ]; then
    # Write temporarily outside the repo; we'll move it after cloning
    cat > /mnt/etc/nixos/easy-encryption.nix <<EON
{ config, lib, pkgs, ... }:
{
  # Enable TPM2 stack for automatic unlocking
  security.tpm2 = {
    enable = lib.mkForce true;
  };

  # Use systemd in initrd for TPM2 unlock support
  boot.initrd.systemd.enable = lib.mkForce true;

  # Configure LUKS device with TPM2 auto-unlock
  boot.initrd.luks.devices.cryptroot = {
    device = lib.mkForce "/dev/disk/by-uuid/$LUKS_UUID";
    preLVM = lib.mkForce true;
    # Allow TPM unlock with fallback to recovery key
    crypttabExtraOpts = [ "tpm2-device=auto" "headless=1" "timeout=0" ];
  };

  # Ensure cryptsetup and systemd-cryptenroll are available
  environment.systemPackages = with pkgs; [
    cryptsetup
    tpm2-tools
  ];
}
EON
  else
    # No TPM - encryption only uses recovery key
    cat > /mnt/etc/nixos/easy-encryption.nix <<EON
{ config, lib, pkgs, ... }:
{
  # Use systemd in initrd for better unlock UX
  boot.initrd.systemd.enable = lib.mkForce true;

  # Configure LUKS device (manual unlock required)
  boot.initrd.luks.devices.cryptroot = {
    device = lib.mkForce "/dev/disk/by-uuid/$LUKS_UUID";
    preLVM = lib.mkForce true;
  };

  environment.systemPackages = with pkgs; [ cryptsetup ];
}
EON
  fi
fi

# Detect which channel this ISO was built with
CHANNEL="stable"
if [ -f /etc/easy/channel ]; then
  CHANNEL=$(cat /etc/easy/channel)
fi

echo "⚙ Cloning easyos flake from GitHub..."
mkdir -p /mnt/etc/nixos
GIT_TERMINAL_PROMPT=0 git clone --depth 1 https://github.com/doughty247/easyos.git /mnt/etc/nixos/easyos

# Move generated encryption configuration into the repo if it exists
if [ -f /mnt/etc/nixos/easy-encryption.nix ]; then
  mv -f /mnt/etc/nixos/easy-encryption.nix /mnt/etc/nixos/easyos/easy-encryption.nix
fi

echo "⚙ Importing hardware-configuration.nix into easyos..."
cp /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/nixos/easyos/

if [ "$BOOT_MODE" = "uefi" ]; then
  echo "⚙ Configuring bootloader (systemd-boot)..."
  cat > /mnt/etc/nixos/easyos/easy-bootloader.nix <<'EON'
{ lib, ... }: {
  boot.loader.systemd-boot.enable = lib.mkForce true;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce true;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.grub.devices = lib.mkForce [ ];
}
EON
else
  echo "⚙ Configuring bootloader (GRUB BIOS)..."
  {
    echo '{ lib, ... }: {'
    echo '  boot.loader.systemd-boot.enable = lib.mkForce false;'
    echo '  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;'
    echo '  boot.loader.grub.enable = lib.mkForce true;'
    echo "  boot.loader.grub.devices = lib.mkForce [ \"$DEVICE\" ];"
    echo '}'
  } > /mnt/etc/nixos/easyos/easy-bootloader.nix
fi

echo "⚙ Creating /mnt/etc/easy/config.json..."
mkdir -p /mnt/etc/easy
cp /mnt/etc/nixos/easyos/etc/easy/config.example.json /mnt/etc/easy/config.json
echo "installed" > /mnt/etc/easy/installed
if command -v jq >/dev/null 2>&1; then
  TMP_JSON=$(mktemp)
  jq --arg host "$HOSTNAME" --arg admin "$ADMIN" '.hostName=$host | .users.admin.name=$admin' /mnt/etc/easy/config.json > "$TMP_JSON" && mv "$TMP_JSON" /mnt/etc/easy/config.json
else
  sed -i "s/\"easyos\"/\"$HOSTNAME\"/" /mnt/etc/easy/config.json
  sed -i "s/\"easyadmin\"/\"$ADMIN\"/" /mnt/etc/easy/config.json
fi

# Persist chosen credentials
cat > /mnt/etc/nixos/easyos/easy-credentials.nix <<EOCRED
{ lib, ... }:
{
  users.groups.${ADMIN} = {};

  # Set only initialHashedPassword to allow users to change it later via passwd,
  # and explicitly null out other password fields to avoid option conflicts.
  users.users.${ADMIN} = {
    isNormalUser = lib.mkForce true;
    group = lib.mkForce "${ADMIN}";
    initialHashedPassword = lib.mkForce "${ADMIN_HASH}";
    password = lib.mkForce null;
    initialPassword = lib.mkForce null;
    hashedPassword = lib.mkForce null;
    hashedPasswordFile = lib.mkForce null;
  };

  users.users.root = {
    initialHashedPassword = lib.mkForce "${ROOT_HASH}";
    password = lib.mkForce null;
    initialPassword = lib.mkForce null;
    hashedPassword = lib.mkForce null;
    hashedPasswordFile = lib.mkForce null;
  };
}
EOCRED

echo "$CHANNEL" > /mnt/etc/easy/channel

# Clean up any build artifacts
rm -f /mnt/etc/nixos/easyos/result* 2>/dev/null || true

FLAKE_ATTR="easyos-$CHANNEL"

# Helper: cleanly unmount target and close encryption if used
rollback_mounts() {
  echo "Performing rollback: unmounting target and closing mappings..."
  # Unmount in safe order
  umount /mnt/var 2>/dev/null || true
  umount /mnt/nix 2>/dev/null || true
  umount /mnt/home 2>/dev/null || true
  umount /mnt/boot 2>/dev/null || true
  umount /mnt 2>/dev/null || true
  sync || true
  # Close LUKS mapping if present
  if [ "${ENCRYPT:-0}" -eq 1 ]; then
    cryptsetup close cryptroot 2>/dev/null || true
  fi
}

echo ""
echo "⚙ Installing NixOS with $CHANNEL channel (this will take several minutes)..."
# Temporarily disable 'exit on error' to capture nixos-install exit code and show helpful diagnostics
set +e
nixos-install --flake "/mnt/etc/nixos/easyos#$FLAKE_ATTR" --impure --no-root-passwd --option pure-eval false
INSTALL_RC=$?
set -e

if [ $INSTALL_RC -ne 0 ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║                    ✗ Installation FAILED                      ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Last 80 lines of the installer log ($LOGFILE):"
  echo "────────────────────────────────────────────────────────────────"
  tail -n 80 "$LOGFILE" || true
  echo "────────────────────────────────────────────────────────────────"
  echo ""
  echo "Common causes:"
  echo "  • hardware-configuration.nix not imported or missing root filesystem"
  echo "  • bootloader configuration missing (UEFI vs BIOS)"
  echo "  • Network or cache issues during nix build"
  echo ""
  prompt "Rollback mounts and return to shell? [Y/n]: " RB
  RB=${RB:-Y}
  if [[ ! "$RB" =~ ^[Yy]$ ]]; then
    echo "Leaving mounts as-is for manual inspection."
    exit 1
  fi
  rollback_mounts
  echo "Rollback complete. You can inspect logs with: less $LOGFILE"
  exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║            ✓ Installation Complete!                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Installed channel: $CHANNEL"
echo ""
if [ "${ENCRYPT:-0}" -eq 1 ]; then
  echo "Disk encryption: ENABLED (TPM2 auto-unlock)"
  echo "Recovery key stored at: /etc/easy/recovery.key"
  echo ""
fi
echo "What happens on first boot:"
echo "  • Auto-login as '$ADMIN'"
echo "  • WiFi hotspot will start (if WiFi adapter present)"
echo "  • Web UI available at http://<ip>:8088/"
echo ""
if [ -d /mnt/etc ]; then
  cp -f "$LOGFILE" /mnt/etc/easyos-install.log || true
fi
prompt "Press ENTER to reboot now, or Ctrl+C to stay in the live environment..." _
reboot
