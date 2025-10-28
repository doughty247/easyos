{ lib, config, pkgs, inputs, ... }:
let
  # Impure JSON read: requires --impure at rebuild time
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  adminUser = if (cfgJSON ? users && cfgJSON.users ? admin && cfgJSON.users.admin ? username)
              then cfgJSON.users.admin.username else "easyadmin";
  adminKeys = if (cfgJSON ? users && cfgJSON.users ? admin && cfgJSON.users.admin ? sshAuthorizedKeys)
              then cfgJSON.users.admin.sshAuthorizedKeys else [];
  tz = if (cfgJSON ? timeZone) then cfgJSON.timeZone else "UTC";
  hostName = if (cfgJSON ? hostName) then cfgJSON.hostName else "easyos";
  swapSizeMiB = if (cfgJSON ? swapMiB) then cfgJSON.swapMiB else 8192; # 8 GiB default
in {
  options.easyos.enable = lib.mkEnableOption "Enable EASYOS base configuration";

  config = lib.mkIf (config.easyos.enable or true) {
    # Base identification
    networking.hostName = hostName;

    # Bootloader (UEFI systemd-boot)
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

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

    # Networking backend: systemd-networkd
    networking.useNetworkd = true;
    systemd.network.enable = true;

    # SSH access (password auth off by default)
    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    # Useful tools
    environment.systemPackages = with pkgs; [
      curl wget git htop tmux jq
      mtr traceroute bind.tools
      btrfs-progs
      nano vim
    ];

    # Nix & flakes
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Admin user
    users.users.${adminUser} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "audio" ];
      openssh.authorizedKeys.keys = adminKeys;
    };

    # Home Manager baseline for admin user
    home-manager.users.${adminUser} = { pkgs, ... }: {
      home.stateVersion = "24.11";
      programs.git.enable = true;
      programs.tmux.enable = true;
      programs.bash.enable = true;
    };

    # Firewall defaults on; modules can open ports as needed
    networking.firewall.enable = true;

    # Keep system state version in sync with release used
    system.stateVersion = "24.11";
  };
}
