{ lib, config, pkgs, inputs, ... }:
let
  # Impure JSON read: requires --impure at rebuild time
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  # Align with example schema keys
  adminUser = if (cfgJSON ? users && cfgJSON.users ? admin && cfgJSON.users.admin ? name)
              then cfgJSON.users.admin.name else "easyadmin";
  adminKeys = if (cfgJSON ? users && cfgJSON.users ? admin && cfgJSON.users.admin ? authorizedKeys)
              then cfgJSON.users.admin.authorizedKeys else [];
  tz = if (cfgJSON ? timeZone) then cfgJSON.timeZone else "UTC";
  hostName = if (cfgJSON ? hostName) then cfgJSON.hostName else "easyos";
  swapSizeMiB = if (cfgJSON ? swapMiB) then cfgJSON.swapMiB else 8192; # 8 GiB default
  firstRun = if (cfgJSON ? mode) then (cfgJSON.mode == "first-run") else true;
in {
  options.easyos.enable = lib.mkEnableOption "Enable EASYOS base configuration";

  config = lib.mkIf (config.easyos.enable or true) {
    # Pin the state version for stable option semantics
    system.stateVersion = lib.mkDefault "24.11";
  # Base identification
  networking.hostName = hostName;

    # Bootloader (UEFI systemd-boot only, explicitly disable grub)
  boot.loader.systemd-boot.enable = lib.mkForce true;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce true;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.grub.devices = lib.mkForce [ ];

    # LTS Linux kernel for stability
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;

    # Quiet boot - reduce console spam but don't break boot
    boot.kernelParams = [
      "quiet"                     # Suppress most kernel messages
      "loglevel=3"                # Only show errors and warnings
      "systemd.show_status=auto"  # Only show status on errors
      "rd.udev.log_level=3"       # Reduce udev noise
    ];

    # Kernel modules for common hardware
    boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
    boot.kernelModules = [ "kvm-intel" "kvm-amd" ];

    # Filesystem configuration (btrfs with subvolumes)
    # These are defaults - hardware-configuration.nix will override them during installation
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [ "subvol=root" "compress=zstd" ];
    };

    fileSystems."/home" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [ "subvol=home" "compress=zstd" ];
    };

    fileSystems."/nix" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [ "subvol=nix" "compress=zstd" "noatime" ];
    };

    fileSystems."/var" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [ "subvol=var" "compress=zstd" ];
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
    };

    # Swap file
    swapDevices = [ { device = "/swapfile"; size = swapSizeMiB; } ];

    # Locale & console
    i18n.defaultLocale = "en_US.UTF-8";
    time.timeZone = tz;
    console.keyMap = "us";

    # Headless server; keep audio for optional speaker features
    services.xserver.enable = false;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    # Networking backend: NetworkManager (works better with WiFi/hotspots)
    networking.networkmanager.enable = true;
    networking.useNetworkd = false;
    systemd.network.enable = false;
    networking.wireless.enable = false; # Disable wpa_supplicant in favor of NetworkManager

    # SSH access (password auth off by default, enabled during first-run)
    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = firstRun; # Allow password auth during first-run
        PermitRootLogin = "prohibit-password";
      };
    };

    # Useful tools
    environment.systemPackages = with pkgs; [
      curl wget git htop tmux jq
      mtr traceroute bind.tools
      btrfs-progs
      nano vim
      # Help command for EasyOS
      (pkgs.writeShellScriptBin "easy-help" ''
        cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                      EasyOS Quick Help                         ║
╚════════════════════════════════════════════════════════════════╝

SYSTEM INFORMATION
  cat /etc/easy/channel          Check update channel (stable/beta/preview)
  cat /etc/easy/config.json      View system configuration
  systemctl status easyos-*      Check EasyOS services status
  
NETWORKING
  sudo nmtui                       Configure network connections
  nmcli device wifi list           List available Wi-Fi networks
  nmcli connection show            Show network connections
  ip addr show                     Show IP addresses

HOTSPOT & ACCESS POINT
  sudo systemctl start easyos-hotspot   Start Wi-Fi hotspot
  sudo systemctl stop easyos-hotspot    Stop Wi-Fi hotspot
  sudo systemctl status easyos-hotspot  Check hotspot status

BACKUP & STORAGE
  sudo systemctl start easyos-backup    Run backup to USB/external drive
  df -h                                 Check disk space usage
  sudo btrfs filesystem usage /         Detailed Btrfs space info
  sudo btrfs subvolume list /           List Btrfs subvolumes

WEB INTERFACE
  The EasyOS web UI is available at:
    http://localhost:8080 (or your device's IP)
  To find your IP: ip addr show

CONFIGURATION
  Edit config:    sudo nano /etc/easy/config.json
  Apply changes:  sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
  View channel:   cat /etc/easy/channel

TROUBLESHOOTING
  journalctl -u easyos-*        View EasyOS service logs
  journalctl -b                 View boot logs
  journalctl -f                 Follow live system logs
  dmesg                         View kernel messages

USER MANAGEMENT
  passwd                        Change your password
  sudo passwd root              Change root password
  sudo useradd -m username      Add new user

DOCUMENTATION
  README: /etc/nixos/easyos/README.md
  GitHub: https://github.com/doughty247/easyos

NIXOS COMMANDS
  nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
                                Apply configuration changes
  nixos-help                    NixOS documentation
  nix-shell                     Enter development environment
  nix-collect-garbage -d        Clean up old system generations

═══════════════════════════════════════════════════════════════════
Type 'easy-help' anytime to see this message again.
EOF
      '')
    ];

    # Nix & flakes
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Admin user - use proper NixOS password management
    users.users.${adminUser} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      openssh.authorizedKeys.keys = adminKeys;
      # NixOS properly handles initialPassword - no need for chpasswd hacks
      initialPassword = "easyos";
    };

    # Root password for recovery access
    users.users.root.initialPassword = "easyos";
    
    # Allow wheel group sudo without password during first-run for ease of setup
    security.sudo.wheelNeedsPassword = !firstRun;

    # Proper autologin configuration - use NixOS builtin support
    # Reference: nixos/modules/services/ttys/getty.nix
    services.getty.autologinUser = lib.mkIf firstRun adminUser;
    
    # Clear screen on tty1 to hide boot logs before login
    systemd.services."getty@tty1".serviceConfig = lib.mkIf firstRun {
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYVTDisallocate = true;  # Clear VT on exit
      TTYReset = true;          # Reset terminal
    };

    # Display first-run welcome message on console login
    # Use bash loginShellInit instead of profile.d for reliability
    programs.bash.loginShellInit = lib.mkIf firstRun ''
      # Only show on tty1 and only once per login session
      if [ "$(tty)" = "/dev/tty1" ] && [ -z "$EASYOS_WELCOME_SHOWN" ]; then
        export EASYOS_WELCOME_SHOWN=1
        
        # Clear screen to hide boot logs
        clear
        
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║              Welcome to EASYOS First-Run Setup            ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Logged in as: ${adminUser}"
        echo "Default password: easyos (change immediately!)"
        echo ""
        echo "Setup Options:"
        echo ""
        echo "  1. Web UI Setup (Recommended):"
        echo "     • Connect via Ethernet: ip addr show"
        echo "     • Open http://<ip-address>:8088/ in browser"
        echo "     • Configure and set secure password"
        echo ""
        echo "  2. WiFi Hotspot (if adapter available):"
        echo "     • SSID: ${if (cfgJSON ? network && cfgJSON.network ? ssid) then cfgJSON.network.ssid else "EASY-Setup"}"
        echo "     • Connect and go to: http://10.42.0.1:8088/"
        echo ""
        echo "  3. Console Setup:"
        echo "     • Set password: passwd"
        echo "     • Edit config: sudo nano /etc/easy/config.json"
        echo "     • Apply: sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos"
        echo ""
        echo "Commands: easy-help | ip addr | nmcli device | journalctl -f | sudo reboot"
        echo ""
      fi
    '';
    
    # Show helpful tip on every interactive login (not just first-run)
    programs.bash.interactiveShellInit = ''
      # Show tip on login for all users
      if [ -z "$EASYOS_TIP_SHOWN" ]; then
        export EASYOS_TIP_SHOWN=1
        echo ""
        echo "💡 Type 'easy-help' for quick commands and documentation."
        echo ""
      fi
    '';

    # Home Manager baseline for admin user
    home-manager.users.${adminUser} = { pkgs, ... }: {
      home.stateVersion = "24.11";
      programs.git.enable = true;
      programs.tmux.enable = true;
      programs.bash.enable = true;
    };

    # Firewall defaults on; modules can open ports as needed
    networking.firewall.enable = true;

    # system.stateVersion is set above with mkDefault; do not set twice
  };
}
