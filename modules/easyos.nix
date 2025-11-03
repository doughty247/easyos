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
  system.stateVersion = lib.mkForce "24.11";
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

    # Fix systemd random seed warnings by ensuring proper permissions
    systemd.tmpfiles.rules = [
      "d /var/lib/systemd 0755 root root -"
      "d /var/lib/systemd/random-seed 0700 root root -"
    ];

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

EasyOS Quick Reference
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SYSTEM INFORMATION
    cat /etc/easy/channel               Show update channel (stable/beta/preview)
    cat /etc/easy/config.json           View system configuration
    systemctl status easyos-*           Check EasyOS service status
    uname -r                            Show kernel version
    hostnamectl                         Show hostname and system info

NETWORKING
    sudo nmtui                          Network configuration (TUI)
    nmcli device wifi list              List available Wi-Fi networks
    nmcli connection show               Show all network connections
    ip addr show                        Show IP addresses
    ip route show                       Show routing table
    ping -c4 8.8.8.8                    Test internet connectivity

HOTSPOT & ACCESS POINT
    systemctl start easyos-hotspot      Start Wi-Fi hotspot
    systemctl stop easyos-hotspot       Stop Wi-Fi hotspot
    systemctl status easyos-hotspot     Check hotspot status

    Features: Router-grade NAT/masquerading, DHCP/DNS server,
              captive portal detection, client isolation support

NETWORK PERFORMANCE & QoS
    cat /etc/easy/qos-current.json                Current QoS settings
    cat /var/lib/easyos/network-profiles.json     Network speed profiles
    systemctl status easyos-network-autodiscovery Network auto-detection

    Technology: CAKE QoS (bufferbloat control), BBR congestion control,
                per-network bandwidth profiling, TCP Fast Open enabled

BACKUP & STORAGE
    systemctl start easyos-backup       Run backup now
    systemctl status easyos-backup      Check backup status
    df -h                               Disk space usage (human-readable)
    sudo btrfs filesystem usage /       Detailed Btrfs statistics
    sudo btrfs subvolume list /         List Btrfs subvolumes

ENCRYPTION (TPM2/LUKS)
    systemctl status systemd-cryptsetup@*   Check encrypted volumes
    sudo cryptsetup status data             Show encryption details
    sudo systemd-cryptenroll /dev/xxx       Manage TPM enrollment

    Note: If TPM was enabled during install, data partition auto-unlocks.
          Recovery key was displayed as QR code during installation.

WEB INTERFACE
    URL: http://localhost:8088 (or http://<device-ip>:8088)
    Use 'ip addr show' to find your device's IP address

CONFIGURATION
    Edit:       sudo nano /etc/easy/config.json
    Apply:      sudo nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
    Channel:    cat /etc/easy/channel

TROUBLESHOOTING
    journalctl -u easyos-*              EasyOS service logs
    journalctl -b                       Current boot logs
    journalctl -f                       Follow live system logs
    journalctl -xe                      Recent logs with explanations
    dmesg                               Kernel ring buffer
    dmesg | grep -i tpm                 Check TPM detection
    systemctl --failed                  List failed services

USER MANAGEMENT
    passwd                              Change your password
    sudo passwd <username>              Change another user's password
    sudo useradd -m <username>          Add new user
    sudo usermod -aG wheel <username>   Add user to admin group

NIXOS SYSTEM MANAGEMENT
    nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos
                                        Apply configuration changes
    nixos-rebuild boot                  Apply changes at next boot
    nix-collect-garbage -d              Remove old system generations
    nix-channel --update                Update NixOS channels
    nix-env -qa                         Query available packages

DOCUMENTATION & SUPPORT
    Local:  /etc/nixos/easyos/README.md
    Online: https://github.com/doughty247/easyos
    NixOS:  https://nixos.org/manual/nixos/stable/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Type 'man <command>' for detailed help on any command
EOF
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
