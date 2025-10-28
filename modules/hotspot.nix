{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  mode = if (cfgJSON ? mode) then cfgJSON.mode else "normal";
  netCfg = if (cfgJSON ? network) then cfgJSON.network else {};
  wlan = if (netCfg ? interface) then netCfg.interface else "wlan0";
  ssid = if (netCfg ? ssid) then netCfg.ssid else "EASY-Setup";
  psk  = if (netCfg ? psk) then netCfg.psk else "changeme-strong-pass";

  hotspotCIDR = "10.42.0.1/24";
  dhcpRange = "10.42.0.10,10.42.0.150,12h";
  hotspotEnabled = (mode == "first-run") || (mode == "guest");
  captivePort = 8088; # placeholder for web UI captive portal
in {
  options.easyos.hotspot.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable hotspot/guest mode automation (driven by JSON 'mode').";
  };

  config = lib.mkIf (config.easyos.hotspot.enable && hotspotEnabled) {
    assertions = [
      { assertion = ssid != null && psk != null; message = "hotspot: SSID/PSK must be set."; }
    ];

    # Bring up AP interface with static IP
    systemd.network.networks."40-easyos-hotspot" = {
      matchConfig.Name = wlan;
      networkConfig = {
        Address = hotspotCIDR;
        ConfigureWithoutCarrier = true;
        IPForward = true;
      };
    };

    # hostapd for Access Point
    services.hostapd = {
      enable = true;
      interface = wlan;
      ssid = ssid;
      wpaPassphrase = psk;
      hwMode = "g"; # 2.4GHz default
      channel = 6;
    };

    # dnsmasq for DHCP/DNS on hotspot
    services.dnsmasq = {
      enable = true;
      settings = {
        interface = wlan;
        bind-interfaces = true;
        dhcp-range = dhcpRange;
        domain-needed = true;
        bogus-priv = true;
        # Hand out the gateway (AP) address
        dhcp-option = [
          "3,10.42.0.1" # router option
        ];
      };
    };

    # Basic captive-portal-like firewall: isolate clients, allow portal and DNS/DHCP
    networking.firewall = {
      allowedTCPPorts = [ captivePort ];
      allowedUDPPorts = [ 53 67 68 ];
      extraCommands = ''
        # Block forwarding from hotspot to WAN by default
        ${pkgs.iptables}/bin/iptables -A FORWARD -i ${wlan} -j DROP || true
      '';
      extraStopCommands = ''
        ${pkgs.iptables}/bin/iptables -D FORWARD -i ${wlan} -j DROP || true
      '';
    };

    # Optional tiny nginx for first-run/guest portal landing page
    services.nginx = {
      enable = true;
      virtualHosts.default = {
        default = true;
        root = "/etc/easy/portal";
        listen = [ { addr = "0.0.0.0"; port = captivePort; } ];
      };
    };

    # Ship a minimal portal index if not present
    environment.etc."easy/portal/index.html".text = ''
      <!doctype html>
      <html><head><meta charset="utf-8"><title>EASYOS Setup</title>
      <style>body{font-family:sans-serif;margin:3rem;max-width:720px}</style></head>
      <body>
        <h1>EASYOS ${if mode == "first-run" then "First-Run Setup" else "Guest Upload"}</h1>
        <p>This is a placeholder portal page served during ${mode} mode.</p>
        <p>Replace this with your web UI and configure /etc/easy/config.json then run:</p>
        <pre>nixos-rebuild switch --impure --flake .#easyos</pre>
      </body></html>
    '';
  };
}
