{
  description = "easeOS - NixOS-based appliance OS (ISO builder & configs)";

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
              ./modules/apps.nix

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
          # Include webui and hotspot modules in ISO for live testing/configuration
          ./modules/webui.nix
          ./modules/hotspot.nix
          ./modules/apps.nix
          {
            # Set state version for the ISO
            system.stateVersion = "24.11";

            # Channel-specific kernel
            boot.kernelPackages = lib.mkForce pkgs.${chanConfig.kernelPackages};

            # ISO metadata
            isoImage.makeEfiBootable = true;
            isoImage.makeUsbBootable = true;
            isoImage.volumeID = "EASYOS-${lib.toUpper chanConfig.channelName}";
            
            # Fast boot - 1 second timeout for installer
            boot.loader.timeout = lib.mkForce 1;

            # Ship channel marker
            environment.etc."easy/channel".text = chanConfig.channelName;
            
            # Provide a default config for the webui in the ISO
            environment.etc."easy/config.json".text = builtins.toJSON {
              hostName = "easyos";
              timeZone = "UTC";
              mode = "first-run";
            };
            
            # ISO mode marker - enables hotspot and web UI for live installation
            environment.etc."easy/iso-mode".text = "live-installer";

            # Enable NetworkManager and disable wpa_supplicant
            networking.networkmanager.enable = true;
            networking.useNetworkd = lib.mkForce false;
            systemd.network.enable = lib.mkForce false;
            networking.wireless.enable = false;

            # WiFi is managed by NetworkManager for hotspot setup
            # No unmanaged-wifi config needed - hotspot service handles it

            # Autologin to nixos user
            services.getty.autologinUser = lib.mkForce "nixos";

            # Passwordless sudo for nixos user - the installer profile already sets up nixos user
            # Just ensure the groups are correct and sudo works
            security.sudo.wheelNeedsPassword = lib.mkForce false;
            users.users.nixos = {
              # isNormalUser and empty password are already set by installation-device.nix
              extraGroups = lib.mkForce [ "wheel" "networkmanager" "video" ];
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
              git parted gptfdisk networkmanager openssl jq curl
              cryptsetup systemd qrencode w3m
              (writeShellScriptBin "easyos-install" ''
                # Launch captive portal setup UI
                echo "Opening easeOS setup wizard..."
                echo ""
                
                # Check and show service status
                echo "Checking services..."
                systemctl is-active --quiet easyos-hotspot && echo "  Hotspot: active" || echo "  Hotspot: inactive"
                systemctl is-active --quiet easyos-webui && echo "  Web UI: active" || echo "  Web UI: inactive"
                echo ""
                
                # Wait for webui to be ready
                for i in 1 2 3 4 5; do
                  if systemctl is-active --quiet easyos-webui; then
                    break
                  fi
                  echo "Waiting for Web UI service... ($i/5)"
                  sleep 2
                done
                
                # Test if the server is responding
                if curl -s --connect-timeout 2 http://10.42.0.1:1234/api/status >/dev/null 2>&1; then
                  echo "Web UI server is responding!"
                else
                  echo "Warning: Web UI not responding yet. Checking service..."
                  systemctl status easyos-webui --no-pager -l 2>&1 | head -20
                  echo ""
                  echo "Trying anyway..."
                fi
                
                echo ""
                echo "If the browser doesn't open automatically, visit:"
                echo "  http://10.42.0.1:1234"
                echo ""
                echo "Or from another device, connect to WiFi 'easeOS-Setup' and open the URL above."
                echo ""
                echo "For legacy CLI installer, run: sudo /etc/easyos-install.sh"
                
                # Try to open in a browser if available
                if command -v xdg-open &>/dev/null; then
                  xdg-open "http://10.42.0.1:1234" 2>/dev/null &
                elif command -v w3m &>/dev/null; then
                  w3m "http://10.42.0.1:1234"
                elif command -v lynx &>/dev/null; then
                  lynx "http://10.42.0.1:1234"
                else
                  echo "No browser available. Please open http://10.42.0.1:1234 on another device."
                fi
              '')
              # Keep legacy CLI installer available as separate command
              (writeShellScriptBin "easyos-install-cli" ''
                exec /etc/easyos-install.sh "$@"
              '')
              (writeShellScriptBin "easy-help" ''
                cat << 'EOF'

easeOS Setup - Quick Reference
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

WEB-BASED SETUP (RECOMMENDED)
    The setup wizard opens automatically on boot.
    Or run: easyos-install

    From another device:
    1. Connect to WiFi: "easeOS-Setup" (open, no password)
    2. Open browser: http://10.42.0.1:1234
    3. Follow the setup wizard to install easeOS

CLI INSTALLER (ALTERNATIVE)
    sudo easyos-install-cli           Launch CLI installer
    sudo nmtui                        Configure network first

INSTALLER FEATURES
    ✓ Guided web wizard OR traditional CLI
    ✓ Automatic disk partitioning with Btrfs
    ✓ Optional TPM2-backed LUKS encryption
    ✓ QR code display for recovery keys
    ✓ Update channel selection (stable/beta/preview)

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
    journalctl -u easyos-hotspot        Hotspot service logs
    journalctl -u easyos-webui          Web UI service logs
    dmesg                               Kernel messages

DOCUMENTATION
    GitHub: https://github.com/doughty247/easyos

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Type 'easy-help' anytime to see this message
EOF
              '')
            ];

            # Auto-start captive portal on login
            programs.bash.interactiveShellInit = ''
              # Show helpful tip on login
              echo ""
              echo "Welcome to easeOS! Type 'easy-help' for quick commands and documentation."
              echo ""

              # Only run once per boot
              if [ ! -f /tmp/easyos-setup-run ]; then
                touch /tmp/easyos-setup-run
                
                # Show diagnostic information first
                echo "=== System Diagnostics ==="
                echo ""
                echo "Marker files:"
                ls -la /etc/easy/ 2>&1 || echo "  /etc/easy/ not found!"
                echo ""
                
                echo "Service status:"
                echo "  easyos-hotspot: $(systemctl is-active easyos-hotspot 2>/dev/null || echo 'not found')"
                echo "  easyos-webui: $(systemctl is-active easyos-webui 2>/dev/null || echo 'not found')"
                echo "  NetworkManager: $(systemctl is-active NetworkManager 2>/dev/null || echo 'not found')"
                echo ""
                
                echo "WiFi devices:"
                nmcli device 2>&1 || echo "  nmcli failed"
                echo ""
                
                echo "Network connections:"
                nmcli connection show 2>&1 || echo "  no connections"
                echo ""
                
                # If hotspot service failed, show logs
                if ! systemctl is-active --quiet easyos-hotspot 2>/dev/null; then
                  echo "=== Hotspot service logs ==="
                  journalctl -u easyos-hotspot --no-pager -n 30 2>&1 || echo "No logs available"
                  echo ""
                fi
                
                # If webui service failed, show logs
                if ! systemctl is-active --quiet easyos-webui 2>/dev/null; then
                  echo "=== Web UI service logs ==="
                  journalctl -u easyos-webui --no-pager -n 30 2>&1 || echo "No logs available"
                  echo ""
                fi

                # Check if hotspot is already running (set up by easyos-hotspot.service)
                HOTSPOT_ACTIVE=$(nmcli -t connection show --active 2>/dev/null | grep -c "easyos-hotspot" || true)
                
                if [ "''${HOTSPOT_ACTIVE}" -ge 1 ]; then
                  echo ""
                  echo "Setup hotspot active! Checking Web UI service..."
                  
                  # Wait for webui service to be ready
                  for i in 1 2 3 4 5; do
                    if systemctl is-active --quiet easyos-webui 2>/dev/null; then
                      echo "Web UI service is running."
                      break
                    fi
                    echo "Waiting for Web UI... ($i/5)"
                    sleep 2
                  done
                  
                  # Check if it's actually responding
                  if curl -s --connect-timeout 2 http://10.42.0.1:1234/api/status >/dev/null 2>&1; then
                    echo "Web UI is responding!"
                  else
                    echo ""
                    echo "Web UI not responding. Service status:"
                    systemctl status easyos-webui --no-pager 2>&1 | head -15 || true
                    echo ""
                  fi
                  
                  echo ""
                  
                  # Auto-launch the captive portal in a text browser
                  # This provides immediate visual feedback and interactive setup
                  if command -v w3m &>/dev/null; then
                    echo "Launching setup wizard in w3m browser..."
                    echo "(Press 'q' to exit browser, then type 'easyos-install' to relaunch)"
                    sleep 2
                    w3m http://10.42.0.1:1234
                  else
                    # Fallback to showing info if no text browser
                    echo "╔══════════════════════════════════════════════════════════════════╗"
                    echo "║                    easeOS Setup Ready!                            ║"
                    echo "╠══════════════════════════════════════════════════════════════════╣"
                    echo "║                                                                   ║"
                    echo "║  Connect to the Wi-Fi hotspot from another device:               ║"
                    echo "║    SSID: easeOS-Setup (open, no password)                        ║"
                    echo "║                                                                   ║"
                    echo "║  Then open your browser to complete setup:                        ║"
                    echo "║    http://10.42.0.1:1234                                          ║"
                    echo "║                                                                   ║"
                    echo "║  Or use the CLI installer:                                        ║"
                    echo "║    sudo easyos-install-cli                                        ║"
                    echo "║                                                                   ║"
                    echo "╚══════════════════════════════════════════════════════════════════╝"
                    echo ""
                  fi
                else
                  # No hotspot (maybe no WiFi hardware) - offer CLI installer
                  echo ""
                  echo "╔══════════════════════════════════════════════════════════════════╗"
                  echo "║                        easeOS Setup                               ║"
                  echo "╠══════════════════════════════════════════════════════════════════╣"
                  echo "║                                                                   ║"
                  echo "║  No Wi-Fi hotspot available. Use the CLI installer:              ║"
                  echo "║    sudo easyos-install-cli                                        ║"
                  echo "║                                                                   ║"
                  echo "║  Or configure network first:                                      ║"
                  echo "║    sudo nmtui                                                     ║"
                  echo "║                                                                   ║"
                  echo "╚══════════════════════════════════════════════════════════════════╝"
                  echo ""
                fi
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

      # Development shell for EasyOS development
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            name = "easyos-dev";
            
            buildInputs = with pkgs; [
              # Nix tools
              nix
              nixos-rebuild
              
              # Build & test
              qemu_kvm
              OVMF
              
              # Utilities
              jq
              shellcheck
              git
              curl
              
              # For installer script testing
              cryptsetup
              parted
              dosfstools
            ];
            
            shellHook = ''
              echo ""
              echo "╔══════════════════════════════════════════════════════════╗"
              echo "║            EasyOS Development Environment                ║"
              echo "╠══════════════════════════════════════════════════════════╣"
              echo "║  Commands:                                               ║"
              echo "║    build-iso      - Build the ISO                        ║"
              echo "║    test-vm        - Launch VM with current ISO           ║"
              echo "║    check-flake    - Validate flake syntax                ║"
              echo "║    lint-scripts   - Run shellcheck on scripts            ║"
              echo "╚══════════════════════════════════════════════════════════╝"
              echo ""
              
              export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
              export OVMF_VARS="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
              
              build-iso() {
                echo "Building EasyOS ISO..."
                nix build .#nixosConfigurations.iso.config.system.build.isoImage -o iso-result
                ISO=$(find iso-result -name "*.iso" | head -1)
                if [ -n "$ISO" ]; then
                  mkdir -p iso-output
                  cp -L "$ISO" iso-output/
                  echo "ISO ready: iso-output/$(basename "$ISO")"
                fi
              }
              
              test-vm() {
                ISO=$(find iso-output -name "*.iso" 2>/dev/null | head -1)
                if [ -z "$ISO" ]; then
                  echo "No ISO found. Run build-iso first."
                  return 1
                fi
                
                VM_DISK="/tmp/easyos-test.img"
                [ ! -f "$VM_DISK" ] && qemu-img create -f qcow2 "$VM_DISK" 20G
                
                echo "Starting VM with $ISO"
                echo "WebUI will be at http://localhost:1234/"
                
                qemu-system-x86_64 \
                  -machine type=q35,accel=kvm \
                  -cpu host -smp 2 -m 8G \
                  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
                  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
                  -drive file="$VM_DISK",format=qcow2,if=virtio \
                  -cdrom "$ISO" \
                  -boot d \
                  -net nic,model=virtio \
                  -net user,hostfwd=tcp::1234-:1234
              }
              
              check-flake() {
                nix flake check --no-build
              }
              
              lint-scripts() {
                shellcheck scripts/*.sh 2>/dev/null || echo "No scripts to lint or shellcheck found issues"
              }
              
              # Copy OVMF vars for VM use
              [ ! -f /tmp/OVMF_VARS.fd ] && cp "$OVMF_VARS" /tmp/OVMF_VARS.fd 2>/dev/null || true
            '';
          };
        }
      );
    };
}
