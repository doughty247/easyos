{
  description = "easyos - NixOS-based EASY appliance (WIP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      lib = nixpkgs.lib;
    in {
      # Developer convenience: formatter
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      nixosConfigurations = {
        easyos = lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; }; # pass inputs to modules
          modules = [
            ./modules/easyos.nix
            ./modules/hotspot.nix
            ./modules/backup.nix
            ./modules/storage-expansion.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
            }
          ];
        };

        # Bootable ISO installer with easyos pre-configured
        iso = lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./modules/easyos.nix
            ./modules/hotspot.nix
            ./modules/backup.nix
            ./modules/storage-expansion.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;

              # ISO-specific overrides
              isoImage.makeEfiBootable = true;
              isoImage.makeUsbBootable = true;
              isoImage.volumeID = "EASYOS";

              # Ship the flake source in the ISO for easy installation
              environment.systemPackages = [ 
                nixpkgs.legacyPackages.x86_64-linux.git 
                nixpkgs.legacyPackages.x86_64-linux.parted
                nixpkgs.legacyPackages.x86_64-linux.gptfdisk
              ];
              
              # Create installer script in /root and symlink to /etc
              environment.etc."easyos-install.sh" = {
                text = ''
                  #!/usr/bin/env bash
                  set -euo pipefail
                  
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
                    read -p "Target device (e.g., /dev/sda or /dev/nvme0n1): " DEVICE
                    
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
                    read -p "Type 'YES' in all caps to confirm: " CONFIRM
                    
                    if [ "$CONFIRM" = "YES" ]; then
                      break
                    else
                      echo "Installation cancelled."
                      exit 1
                    fi
                  done
                  
                  # Get hostname
                  read -p "Hostname for this system [easyos]: " HOSTNAME
                  HOSTNAME=''${HOSTNAME:-easyos}
                  
                  echo ""
                  echo "══════════════════════════════════════════════════════════════"
                  echo "Installation Summary:"
                  echo "  Target: $DEVICE"
                  echo "  Hostname: $HOSTNAME"
                  echo "══════════════════════════════════════════════════════════════"
                  echo ""
                  read -p "Press ENTER to begin installation or Ctrl+C to cancel..."
                  
                  echo ""
                  echo "⚙ Partitioning $DEVICE..."
                  parted -s "$DEVICE" -- mklabel gpt
                  parted -s "$DEVICE" -- mkpart ESP fat32 1MiB 512MiB
                  parted -s "$DEVICE" -- set 1 esp on
                  parted -s "$DEVICE" -- mkpart primary btrfs 512MiB 100%
                  
                  # Handle both /dev/sdX and /dev/nvmeXnY naming
                  if [[ "$DEVICE" =~ "nvme" ]]; then
                    BOOT="''${DEVICE}p1"
                    ROOT="''${DEVICE}p2"
                  else
                    BOOT="''${DEVICE}1"
                    ROOT="''${DEVICE}2"
                  fi
                  
                  sleep 2  # Wait for kernel to recognize partitions
                  
                  echo "⚙ Formatting partitions..."
                  mkfs.fat -F 32 -n BOOT "$BOOT"
                  mkfs.btrfs -f -L nixos "$ROOT"
                  
                  echo "⚙ Creating btrfs subvolumes..."
                  mount "$ROOT" /mnt
                  btrfs subvolume create /mnt/root
                  btrfs subvolume create /mnt/home
                  btrfs subvolume create /mnt/nix
                  btrfs subvolume create /mnt/var
                  umount /mnt
                  
                  echo "⚙ Mounting filesystems..."
                  mount -o subvol=root,compress=zstd "$ROOT" /mnt
                  mkdir -p /mnt/{home,nix,var,boot}
                  mount -o subvol=home,compress=zstd "$ROOT" /mnt/home
                  mount -o subvol=nix,compress=zstd,noatime "$ROOT" /mnt/nix
                  mount -o subvol=var,compress=zstd "$ROOT" /mnt/var
                  mount "$BOOT" /mnt/boot
                  
                  echo "⚙ Cloning easyos flake to /mnt/etc/nixos..."
                  mkdir -p /mnt/etc/nixos
                  git clone https://github.com/YOUR_USERNAME/easyos.git /mnt/etc/nixos/easyos
                  
                  echo "⚙ Creating /mnt/etc/easy/config.json..."
                  mkdir -p /mnt/etc/easy
                  cp /mnt/etc/nixos/easyos/etc/easy/config.example.json /mnt/etc/easy/config.json
                  sed -i "s/\"easyos\"/\"$HOSTNAME\"/" /mnt/etc/easy/config.json
                  
                  echo ""
                  echo "⚙ Installing NixOS (this will take several minutes)..."
                  nixos-install --flake /mnt/etc/nixos/easyos#easyos --impure --no-root-passwd
                  
                  echo ""
                  echo "╔════════════════════════════════════════════════════════════════╗"
                  echo "║            ✓ Installation Complete!                           ║"
                  echo "╚════════════════════════════════════════════════════════════════╝"
                  echo ""
                  echo "Next steps:"
                  echo "  1. Reboot the system"
                  echo "  2. Remove the installation media"
                  echo "  3. Edit /etc/easy/config.json to:"
                  echo "     • Add your SSH keys to users.admin.authorizedKeys"
                  echo "     • Set your timezone"
                  echo "     • Configure any optional features (backups, hotspot, etc.)"
                  echo "  4. Apply changes: sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos"
                  echo ""
                  read -p "Press ENTER to reboot now, or Ctrl+C to stay in the live environment..."
                  reboot
                '';
                mode = "0755";
              };
              
              # Make installer accessible in root home
              system.activationScripts.easyosInstaller = ''
                ln -sf /etc/easyos-install.sh /root/install.sh
              '';
            }
          ];
        };
      };
    };
}
