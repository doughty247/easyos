# TPM2 Auto-Unlock Fix

## Problem
TPM2 enrollment succeeded during installation, but the system still prompted for the recovery key on boot instead of auto-unlocking.

## Root Cause
The TPM kernel modules (`tpm_crb` and `tpm_tis`) were not being loaded in the initramfs, preventing systemd-cryptsetup from accessing the TPM during boot.

## Research
Analyzed Bazzite Linux's working `ujust setup-luks-tpm-unlock` implementation:
- Source: https://github.com/ublue-os/bazzite/commit/5402f530ef2cfe9403fc0baee79c664699a811d2
- Key finding: They directly modify `/etc/crypttab` to add `tpm2-device=auto`
- EasyOS uses NixOS's `crypttabExtraOpts` which should have the same effect

## Solution
Updated `easy-encryption.nix` generation in the installer to include:

```nix
# Ensure TPM2 kernel modules are loaded in initrd for unlock
boot.initrd.availableKernelModules = [ "tpm_crb" "tpm_tis" ];
```

This ensures the TPM drivers are available in the initramfs when systemd-cryptsetup attempts to unlock the LUKS volume.

## How It Works
1. **Installer enrollment**: `systemd-cryptenroll` binds LUKS unlock to TPM PCRs 0+2+7 (firmware, kernel, Secure Boot)
2. **NixOS config**: `crypttabExtraOpts = [ "tpm2-device=auto" ]` tells systemd-cryptsetup to try TPM unlock
3. **Initrd modules**: `tpm_crb` and `tpm_tis` drivers allow initrd to communicate with TPM hardware
4. **Boot sequence**:
   - Initramfs loads TPM drivers
   - systemd-cryptsetup detects `tpm2-device=auto` in crypttab
   - Attempts TPM unlock using bound PCRs
   - If successful, volume unlocks automatically
   - If failed (e.g., UEFI update changed PCRs), prompts for recovery key

## Testing
To test the fix:
1. Rebuild ISO: `podman run --rm -i --privileged -v /home/bazzite/Documents/easy/easyos:/workspace -v easyos-nix-store:/nix -v easyos-var-cache:/var/cache easyos-builder /workspace/build-iso-docker.sh`
2. Install on hardware with TPM2
3. After installation, system should boot directly to login without passphrase prompt

## Verification Commands (Post-Boot)
```bash
# Check TPM modules are loaded
lsmod | grep tpm

# Check LUKS keyslots (should show TPM2 token)
sudo cryptsetup luksDump /dev/disk/by-uuid/<uuid>

# Check systemd-cryptsetup logs
journalctl -u systemd-cryptsetup@*

# Check initramfs contents (should include TPM modules)
lsinitrd /boot/initramfs-*.img | grep tpm
```

## Fallback
If TPM unlock fails (e.g., firmware update):
- System prompts for recovery key interactively
- Recovery key is displayed as QR code during installation and saved to `/etc/easy/recovery.key`
- Emergency access is enabled in initrd for troubleshooting
