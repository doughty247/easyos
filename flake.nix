{
  description = "easyos - NixOS-based EASY appliance (ISO builder & configs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs systems;

      # EASY Update Channels (SteamOS-style)
      channelConfig = channel: {
        stable = {
          kernelPackages = "linuxPackages";
          channelName = "stable";
        };
        beta = {
          kernelPackages = "linuxPackages";
          channelName = "beta";
        };
        preview = {
          kernelPackages = "linuxPackages_latest";
          channelName = "preview";
        };
      }.${channel};

      # Base EASYOS configuration (intended for installed systems)
      mkEasyOS = { system ? "x86_64-linux", channel ? "stable" }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          chanConfig = channelConfig channel;
          # Helper to optionally import files the installer writes
          maybeImport = path: lib.optional (builtins.pathExists path) path;
        in lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules =
            [
              # Core EASYOS modules
              ./modules/easyos.nix
              ./modules/network-performance.nix
              ./modules/network-autodiscovery.nix
              ./modules/hotspot.nix
              ./modules/backup.nix
              ./modules/storage-expansion.nix
              ./modules/webui.nix

              # Home Manager integration
              home-manager.nixosModules.home-manager
              {
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;

                # Channel-specific kernel and marker file
                boot.kernelPackages = lib.mkForce pkgs.${chanConfig.kernelPackages};
                environment.etc."easy/channel".text = chanConfig.channelName;

                # Ensure tooling like systemd-cryptenroll is available post-install
                environment.systemPackages = [ pkgs.systemd ];
              }
            ]
            # Optional imports written by the installer at install-time
            ++ (maybeImport ./hardware-configuration.nix)
            ++ (maybeImport ./easy-bootloader.nix)
            ++ (maybeImport ./easy-credentials.nix)
            ++ (maybeImport ./easy-encryption.nix);
        };

      # Bootable ISO image with live environment and installer
      mkISO = { system ? "x86_64-linux", channel ? "stable" }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          chanConfig = channelConfig channel;
        in nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          (nixpkgs + "/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix")
          {
            # Set state version for the ISO
            system.stateVersion = "24.11";

            # Channel-specific kernel
            boot.kernelPackages = lib.mkForce pkgs.${chanConfig.kernelPackages};

            # ISO metadata
            isoImage.makeEfiBootable = true;
            isoImage.makeUsbBootable = true;
            isoImage.volumeID = "EASYOS-${lib.toUpper chanConfig.channelName}";

            # Ship channel marker
            environment.etc."easy/channel".text = chanConfig.channelName;

            # Enable NetworkManager and disable wpa_supplicant
            networking.networkmanager.enable = true;
            networking.useNetworkd = lib.mkForce false;
            systemd.network.enable = lib.mkForce false;
            networking.wireless.enable = false;

            # Keep WiFi unmanaged by default; re-enable dynamically at login
            environment.etc."NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf" = {
              text = ''
                [keyfile]
                unmanaged-devices=type:wifi
              '';
              mode = "0644";
            };

            # Autologin to nixos user
            services.getty.autologinUser = lib.mkForce "nixos";

            # Passwordless sudo for nixos user
            security.sudo.wheelNeedsPassword = lib.mkForce false;
            users.users.nixos = {
              isNormalUser = true;
              extraGroups = [ "wheel" "networkmanager" ];
              initialPassword = "";
              initialHashedPassword = lib.mkForce null;
              hashedPassword = lib.mkForce null;
              hashedPasswordFile = lib.mkForce null;
              password = lib.mkForce null;
            };
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

            # Helpful tools for the ISO
            environment.systemPackages = with pkgs; [
              git parted gptfdisk networkmanager openssl jq
              cryptsetup systemd qrencode
              (writeShellScriptBin "easyos-install" ''
                exec /etc/easyos-install.sh "$@"
              '')
              (writeShellScriptBin "easy-help" ''
                cat << 'EOF'

EasyOS Installer - Quick Reference
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GETTING STARTED
    easyos-install                      Launch the installer
    sudo nmtui                          Configure network (if needed)
  Note: Internet is required (installer fetches latest flake and uses caches)

INSTALLER FEATURES
    • Automatic disk partitioning with Btrfs
    • Optional TPM2-backed LUKS encryption
    • QR code display for recovery keys
  • Network connectivity verification (prompts for nmtui if offline)
    • Update channel selection (stable/beta/preview)

SYSTEM INFORMATION
    lsblk                               List block devices
    lsblk -f                            Show filesystem types
    cat /etc/easy/channel               Show ISO channel
    dmesg | grep -i tpm                 Check TPM2 detection
    ip addr show                        Show IP addresses

NETWORK SETUP
    sudo nmtui                          Network Manager TUI
    nmcli device wifi list              List Wi-Fi networks
    nmcli connection show               Show connections
    ping -c4 8.8.8.8                    Test connectivity

TROUBLESHOOTING
    journalctl -b                       View boot logs
    journalctl -f                       Follow live logs
    dmesg                               Kernel messages
    cat /tmp/easyos-install.log         Installer log (after install)

DOCUMENTATION
    README: /etc/nixos/easyos/README.md
    GitHub: https://github.com/doughty247/easyos

POST-INSTALL FEATURES
  • Open Wi‑Fi hotspot (no WPA) with captive portal
    - SSID: EASY-Setup (always visible, no hidden SSID)
    - Captive portal: http://10.42.0.1:8088 (single client)
    - Walled garden: No WAN access by default (set hotspotAllowWAN: true to enable)
    - Client isolation: Prevents hotspot clients from seeing each other
    - mDNS blocked: Reduces device discovery on hotspot subnet
  • Web UI at http://<ip>:8088 for config and nixos-rebuild
  • Router-grade NAT, DHCP/DNS via NetworkManager
  • CAKE QoS with network auto-profiling + BBR congestion control
  • Automatic Btrfs snapshots & backups

SECURITY NOTES
  • Hotspot captive portal bound to 10.42.0.1 only (not exposed on WAN/LAN)
  • Firewall permits DNS/DHCP/HTTP only from hotspot subnet (10.42.0.0/24)
  • TPM2-backed LUKS encryption with PCR7 + first-boot re-enrollment
  • Recovery key QR code display during install for safe backup

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Type 'easy-help' anytime to see this message
EOF
              '')
            ];

            # Auto-run installer on login
            programs.bash.interactiveShellInit = ''
              # Show helpful tip on login
              echo ""
              echo "Welcome to EasyOS! Type 'easy-help' for quick commands and documentation."
              echo ""

              # Only run once per boot
              if [ ! -f /tmp/easyos-installer-run ]; then
                touch /tmp/easyos-installer-run

                # Enable WiFi if no ethernet connected
                ETH_CONNECTED=$(nmcli -t -f TYPE,STATE device 2>/dev/null | grep -c '^ethernet:connected$' || true)

                if [ "''${ETH_CONNECTED}" -ge 1 ]; then
                  echo "✓ Ethernet connection detected"
                  nmcli radio wifi off 2>/dev/null || true
                else
                  echo "No ethernet detected - WiFi enabled for setup"
                  if [ -f /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf ]; then
                    sudo mv /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf \
                       /etc/NetworkManager/conf.d/10-easyos-unmanaged-wifi.conf.disabled 2>/dev/null || true
                    sudo systemctl reload NetworkManager 2>/dev/null || true
                  fi
                  nmcli radio wifi on 2>/dev/null || true
                fi

                # Run installer with sudo
                sudo /etc/easyos-install.sh
              fi
            '';

            # Embed installer script from flake.nix.bak (it's already validated)
            environment.etc."easyos-install.sh" = {
              source = ./scripts/easyos-install.sh;
              mode = "0755";
            };

            # Convenience symlink
            system.activationScripts.easyosInstaller = ''
              ln -sf /etc/easyos-install.sh /root/install.sh
            '';
          }
        ];
      };
    in {
      # Formatter for convenience
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      nixosConfigurations = {
        # Installed system configs (channels)
        easyos = mkEasyOS { };
        easyos-stable = mkEasyOS { channel = "stable"; };
        easyos-beta = mkEasyOS { channel = "beta"; };
        easyos-preview = mkEasyOS { channel = "preview"; };

        # ISO images per channel
        iso = mkISO { };
        iso-stable = mkISO { channel = "stable"; };
        iso-beta = mkISO { channel = "beta"; };
        iso-preview = mkISO { channel = "preview"; };
      };
    };
}
