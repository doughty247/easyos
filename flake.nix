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

      # EASY Update Channels (SteamOS-style)
      # stable: LTS kernel, stable features (default)
      # beta: LTS kernel, beta features
      # preview: Latest kernel, bleeding edge features (manual build only)
      channelConfig = channel: {
        stable = {
          kernelPackages = "linuxPackages"; # LTS
          channelName = "stable";
        };
        beta = {
          kernelPackages = "linuxPackages"; # LTS
          channelName = "beta";
        };
        preview = {
          kernelPackages = "linuxPackages_latest"; # Latest kernel
          channelName = "preview";
        };
      }.${channel};

      # Helper to build NixOS config with channel settings
      mkEasyOS = { system ? "x86_64-linux", channel ? "stable" }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          chanConfig = channelConfig channel;
        in lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; }; # pass inputs to modules
          modules = [
            # Import hardware configuration (required for installed systems)
            ./hardware-configuration.nix
            ./modules/easyos.nix
            ./modules/hotspot.nix
            ./modules/backup.nix
            ./modules/storage-expansion.nix
            ./modules/webui.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              
              # Channel-specific configuration
              boot.kernelPackages = lib.mkForce pkgs.${chanConfig.kernelPackages};
              environment.etc."easy/channel".text = chanConfig.channelName;
            }
          ] ++ lib.optional (builtins.pathExists ./easy-bootloader.nix) ./easy-bootloader.nix
            ++ lib.optional (builtins.pathExists ./easy-credentials.nix) ./easy-credentials.nix;
        };

      # Helper to build ISO with channel settings
      mkISO = { system ? "x86_64-linux", channel ? "stable" }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          chanConfig = channelConfig channel;
        in lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./modules/easyos.nix
            ./modules/hotspot.nix
            ./modules/backup.nix
            ./modules/storage-expansion.nix
            ./modules/webui.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;

              # Set state version for the ISO
              system.stateVersion = "24.11";

              # Channel-specific kernel configuration
              boot.kernelPackages = lib.mkForce pkgs.${chanConfig.kernelPackages};

              # ISO-specific overrides
              isoImage.makeEfiBootable = true;
              isoImage.makeUsbBootable = true;
              isoImage.volumeID = "EASYOS-${lib.toUpper chanConfig.channelName}";

              # Expose the channel inside the live ISO
              environment.etc."easy/channel".text = chanConfig.channelName;

              # Ship this flake's source inside the ISO so installer can copy it
              environment.etc."nixos/easyos".source = self;

              # Ship helpful tools in the ISO
              environment.systemPackages = [ 
                nixpkgs.legacyPackages.x86_64-linux.git 
                nixpkgs.legacyPackages.x86_64-linux.parted
                nixpkgs.legacyPackages.x86_64-linux.gptfdisk
                nixpkgs.legacyPackages.x86_64-linux.networkmanager
                nixpkgs.legacyPackages.x86_64-linux.openssl
                nixpkgs.legacyPackages.x86_64-linux.jq
                # Make installer easily accessible as a command
                (nixpkgs.legacyPackages.x86_64-linux.writeShellScriptBin "easyos-install" ''
                  exec /etc/easyos-install.sh "$@"
                '')
                # Help command for EasyOS documentation and tips
                (nixpkgs.legacyPackages.x86_64-linux.writeShellScriptBin "easy-help" ''
                  cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                      EasyOS Quick Help                         ║
╚════════════════════════════════════════════════════════════════╝

GETTING STARTED
  easyos-install      Run the EasyOS installer
  sudo nmtui          Configure network connections
  easy-help           Show this help message

SYSTEM INFORMATION
  cat /etc/easy/channel          Check update channel (stable/beta/preview)
  systemctl status easyos-*      Check EasyOS services status
  cat /etc/easy/config.json      View system configuration

HOTSPOT & NETWORKING
  sudo systemctl start easyos-hotspot   Start Wi-Fi hotspot (post-install)
  sudo systemctl stop easyos-hotspot    Stop Wi-Fi hotspot
  nmcli device wifi list                List available Wi-Fi networks
  nmcli connection show                 Show network connections

BACKUP & STORAGE
  sudo systemctl start easyos-backup    Run backup to USB/external drive
  df -h                                 Check disk space usage
  sudo btrfs filesystem usage /         Detailed Btrfs space info

WEB INTERFACE
  The EasyOS web UI is available at:
    http://localhost:8080 (or your device's IP)

TROUBLESHOOTING
  journalctl -u easyos-*        View EasyOS service logs
  journalctl -b                 View boot logs
  dmesg                         View kernel messages
  cat /tmp/easyos-install.log   View installer log (if exists)

DOCUMENTATION
  README: /etc/nixos/easyos/README.md
  GitHub: https://github.com/doughty247/easyos

NIXOS COMMANDS
  nixos-rebuild switch          Apply configuration changes
  nixos-help                    NixOS documentation
  nix-shell                     Enter development environment

═══════════════════════════════════════════════════════════════════
EOF
                '')
              ];
              
              # Auto-run installer on login with Ethernet/Wi‑Fi decision and internet check
              programs.bash.interactiveShellInit = ''
                # Show helpful tip on login
                echo ""
                echo "Welcome to EasyOS! Type 'easy-help' for quick commands and documentation."
                echo ""
                
                # Only run once per boot
                if [ ! -f /tmp/easyos-installer-run ]; then
                  touch /tmp/easyos-installer-run
                  
                  # Decide whether to keep Wi‑Fi unmanaged on ISO
                  ETH_CONNECTED=$(nmcli -t -f TYPE,STATE device 2>/dev/null | grep -c '^ethernet:connected$' || true)
                  ETH_PRESENT=$(nmcli -t -f TYPE device 2>/dev/null | grep -c '^ethernet$' || true)

                  if [ "''${ETH_CONNECTED}" -ge 1 ]; then
                    # Ethernet is connected: keep Wi‑Fi fully disabled for stability
                    nmcli radio wifi off || true
                  else
                    # No ethernet link (or no ethernet at all): enable Wi‑Fi setup
                    if [ -f /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf ]; then
                      sudo mv /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf \
                         /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf.disabled 2>/dev/null || true
                      sudo systemctl reload NetworkManager || true
                    fi
                    nmcli radio wifi on || true
                    
                    # Give NetworkManager time to initialize Wi-Fi and scan
                    echo "Scanning for Wi-Fi networks..."
                    sleep 2
                    # Trigger active Wi-Fi scan
                    nmcli device wifi list --rescan yes > /dev/null 2>&1 || true
                    sleep 1
                  fi
                  
                  # Check internet connectivity
                  if ! curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
                    echo ""
                    echo "⚠ No internet connection detected."
                    echo "  Opening network configuration..."
                    echo ""
                    sleep 1
                    
                    # Use nmtui (NetworkManager TUI) for easy network setup
                    sudo nmtui
                    
                    # Check again after network setup
                    if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
                      echo ""
                      echo "✓ Internet connection established!"
                      echo ""
                    else
                      echo ""
                      echo "⚠ Still no internet. You can run 'sudo nmtui' manually to configure."
                      echo ""
                    fi
                  fi
                  
                  # Run installer with sudo (passwordless on live ISO)
                  sudo /etc/easyos-install.sh
                fi
              '';
              
              # Enable NetworkManager for easier network configuration in ISO
              networking.networkmanager.enable = true;
              networking.useNetworkd = lib.mkForce false;
              systemd.network.enable = lib.mkForce false;
              networking.wireless.enable = false; # Disable wpa_supplicant in favor of NetworkManager

              # Keep Wi‑Fi unmanaged by default on ISO; we'll re-enable it dynamically at login
              environment.etc."NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf" = {
                text = ''
                  [keyfile]
                  unmanaged-devices=type:wifi
                '';
                mode = "0644";
              };

              # Ensure the live ISO logs in automatically so the installer can run
              # The minimal installer image creates a 'nixos' user; we force autologin to it
              services.getty.autologinUser = lib.mkForce "nixos";

              # Make sure the nixos user can sudo without a password (typical for installer ISOs)
              security.sudo.wheelNeedsPassword = lib.mkForce false;
              
              # Ensure nixos user exists and is in wheel group with passwordless sudo
              users.users.nixos = {
                isNormalUser = true;
                extraGroups = [ "wheel" "networkmanager" ];
                # Empty password allows login without password
                initialPassword = "";
              };
              
              # Extra safety: allow wheel group passwordless sudo via sudoers rule
              security.sudo.extraRules = [
                {
                  users = [ "nixos" ];
                  commands = [
                    {
                      command = "ALL";
                      options = [ "NOPASSWD" ];
                    }
                  ];
                }
              ];
              
              # Create installer script in /etc
              environment.etc."easyos-install.sh" = {
                text = ''
                  #!/usr/bin/env bash
                  set -euo pipefail
                  # Log everything to a session log for troubleshooting
                  LOGFILE=/tmp/easyos-install.log
                  exec > >(tee -a "$LOGFILE") 2>&1
                  
                  # Check if running as root
                  if [ "$EUID" -ne 0 ]; then
                    echo "ERROR: This installer must be run as root."
                    echo "Please run: sudo easyos-install"
                    exit 1
                  fi
                  
                  # Check network connectivity and offer setup if needed
                  echo "Checking network connectivity..."
                  if ! curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
                    echo ""
                    echo "⚠ No internet connection detected."
                    echo ""
                    read -p "Configure network now? (Y/n): " SETUP_NET
                    
                    if [[ ! "$SETUP_NET" =~ ^[Nn]$ ]]; then
                      # Ensure Wi‑Fi is managed by NetworkManager
                      if [ -f /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf ]; then
                        mv /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf \
                           /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf.disabled 2>/dev/null || true
                        systemctl reload NetworkManager || true
                      fi
                      nmcli radio wifi on || true
                      
                      # Wait for Wi-Fi to initialize and scan for networks
                      echo "Scanning for Wi-Fi networks..."
                      sleep 2
                      nmcli device wifi list --rescan yes > /dev/null 2>&1 || true
                      sleep 1
                      
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
                        echo "ERROR: Installation requires internet access."
                        echo "Please configure network and try again."
                        exit 1
                      fi
                    else
                      echo ""
                      echo "ERROR: Installation requires internet access."
                      echo "Please configure network with nmtui and try again."
                      exit 1
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

                  # Get admin username
                  read -p "Admin username [easyadmin]: " ADMIN
                  ADMIN=''${ADMIN:-easyadmin}

                  # Get admin password (with confirmation)
                  while true; do
                    stty -echo
                    read -p "Admin password: " ADMIN_PASS; echo
                    read -p "Confirm admin password: " ADMIN_PASS2; echo
                    stty echo
                    if [ "''${ADMIN_PASS}" != "''${ADMIN_PASS2}" ]; then
                      echo "Passwords do not match. Please try again."
                    elif [ -z "''${ADMIN_PASS}" ]; then
                      echo "Password cannot be empty. Please try again."
                    else
                      break
                    fi
                  done

                  # Root password choice
                  read -p "Use the same password for root? [Y/n]: " SAME_ROOT
                  SAME_ROOT=''${SAME_ROOT:-Y}
                  if [[ "$SAME_ROOT" =~ ^[Nn]$ ]]; then
                    while true; do
                      stty -echo
                      read -p "Root password: " ROOT_PASS; echo
                      read -p "Confirm root password: " ROOT_PASS2; echo
                      stty echo
                      if [ "''${ROOT_PASS}" != "''${ROOT_PASS2}" ]; then
                        echo "Passwords do not match. Please try again."
                      elif [ -z "''${ROOT_PASS}" ]; then
                        echo "Password cannot be empty. Please try again."
                      else
                        break
                      fi
                    done
                  else
                    ROOT_PASS="''${ADMIN_PASS}"
                  fi

                  # Hash passwords using SHA-512
                  ADMIN_HASH=$(openssl passwd -6 "''${ADMIN_PASS}")
                  ROOT_HASH=$(openssl passwd -6 "''${ROOT_PASS}")
                  
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
                  
                  echo "⚙ Generating hardware configuration..."
                  nixos-generate-config --root /mnt
                  
                  # Detect which channel this ISO was built with
                  CHANNEL="stable"
                  if [ -f /etc/easy/channel ]; then
                    CHANNEL=$(cat /etc/easy/channel)
                  fi
                  
                  echo "⚙ Setting up easyos flake in /mnt/etc/nixos..."
                  mkdir -p /mnt/etc/nixos
                  
                  # Clone latest flake from GitHub
                  # Nix will automatically use cached packages from ISO when versions match
                  echo "Cloning latest easyos flake from GitHub..."
                  GIT_TERMINAL_PROMPT=0 git clone https://github.com/doughty247/easyos.git /mnt/etc/nixos/easyos
                  
                  echo "⚙ Importing hardware-configuration.nix into easyos..."
                  # Copy hardware config to easyos directory
                  cp /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/nixos/easyos/
                  echo "--- hardware-configuration.nix (installed) ---"
                  cat /mnt/etc/nixos/easyos/hardware-configuration.nix
                  echo "---------------------------------------------"

                  echo "⚙ Forcing systemd-boot and disabling grub (UEFI install)..."
                  cat > /mnt/etc/nixos/easyos/easy-bootloader.nix <<'EON'
                  { lib, ... }: {
                    boot.loader.systemd-boot.enable = lib.mkForce true;
                    boot.loader.efi.canTouchEfiVariables = lib.mkForce true;
                    boot.loader.grub.enable = lib.mkForce false;
                    boot.loader.grub.devices = lib.mkForce [ ];
                  }
                  EON
                  
                  echo "⚙ Creating /mnt/etc/easy/config.json..."
                  mkdir -p /mnt/etc/easy
                  cp /mnt/etc/nixos/easyos/etc/easy/config.example.json /mnt/etc/easy/config.json
                  # Mark system as installed for post-install services
                  echo "installed" > /mnt/etc/easy/installed
                  # Update hostname and admin username in config.json
                  if command -v jq >/dev/null 2>&1; then
                    TMP_JSON=$(mktemp)
                    jq --arg host "$HOSTNAME" --arg admin "$ADMIN" '.hostName=$host | .users.admin.name=$admin' /mnt/etc/easy/config.json > "$TMP_JSON" && mv "$TMP_JSON" /mnt/etc/easy/config.json
                  else
                    # Fallback to sed if jq isn't available (should not happen)
                    sed -i "s/\"easyos\"/\"$HOSTNAME\"/" /mnt/etc/easy/config.json
                    sed -i "s/\"easyadmin\"/\"$ADMIN\"/" /mnt/etc/easy/config.json
                  fi

                  # Persist chosen credentials as a small module to override defaults
                  # Also satisfy NixOS user assertions by declaring a primary group and isNormalUser
                  cat > /mnt/etc/nixos/easyos/easy-credentials.nix <<EOCRED
                  { lib, ... }:
                  {
                    # Ensure a primary group exists for the admin user
                    users.groups.''${ADMIN} = {};

                    users.users.''${ADMIN} = {
                      isNormalUser = lib.mkForce true;
                      group = lib.mkForce "''${ADMIN}";
                      hashedPassword = lib.mkForce "''${ADMIN_HASH}";
                    };

                    users.users.root.hashedPassword = lib.mkForce "''${ROOT_HASH}";
                  }
                  EOCRED
                  
                  # Store channel information
                  echo "$CHANNEL" > /mnt/etc/easy/channel

                  # Determine flake attribute for selected channel (nixos-install expects just the name)
                  FLAKE_ATTR="easyos-$CHANNEL"
                  
                  echo ""
                  echo "⚙ Installing NixOS with $CHANNEL channel (this will take several minutes)..."
                  echo "   Using ISO cache to speed up installation..."
                  
                  nixos-install --flake "/mnt/etc/nixos/easyos#$FLAKE_ATTR" --impure --no-root-passwd --option pure-eval false
                  
                  echo ""
                  echo "⚙ System installation complete!"
                  echo ""
                  echo "╔════════════════════════════════════════════════════════════════╗"
                  echo "║            ✓ Installation Complete!                           ║"
                  echo "╚════════════════════════════════════════════════════════════════╝"
                  echo ""
                  echo "Installed channel: $CHANNEL"
                  echo ""
                  echo "What happens on first boot:"
                  echo "  • Auto-login as '$ADMIN'"
                  echo "  • WiFi hotspot will start (if WiFi adapter present)"
                  echo "  • Web UI available at http://<ip>:8088/"
                  echo ""
                  echo "First-run setup options:"
                  echo "  1. Ethernet: Connect cable, find IP, access web UI"
                  echo "  2. WiFi Hotspot: Connect to 'EASY-Setup', go to http://10.42.0.1:8088/"
                  echo "  3. Console: Follow on-screen instructions after boot"
                  echo ""
                  echo "Use the web UI to set your admin password and configure the system."
                  echo ""
                  # Persist log to target for postmortem
                  if [ -d /mnt/etc ]; then
                    cp -f "$LOGFILE" /mnt/etc/easyos-install.log || true
                  fi
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
    in {
      # Developer convenience: formatter
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      nixosConfigurations = {
        # Default stable channel
        easyos = mkEasyOS { };
        
        # Explicit channel configurations
        easyos-stable = mkEasyOS { channel = "stable"; };
        easyos-beta = mkEasyOS { channel = "beta"; };
        easyos-preview = mkEasyOS { channel = "preview"; };

        # Bootable ISO installers (one per channel)
        iso = mkISO { }; # stable by default
        iso-stable = mkISO { channel = "stable"; };
        iso-beta = mkISO { channel = "beta"; };
        iso-preview = mkISO { channel = "preview"; };
      };
    };
}
