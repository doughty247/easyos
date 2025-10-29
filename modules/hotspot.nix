{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  mode = if (cfgJSON ? mode) then cfgJSON.mode else "first-run";
  netCfg = if (cfgJSON ? network) then cfgJSON.network else {};
  ssid = if (netCfg ? ssid) then netCfg.ssid else "EASY-Setup";
  psk  = if (netCfg ? psk) then netCfg.psk else "changeme-strong-pass";

  hotspotEnabled = (mode == "first-run") || (mode == "guest");
  captivePort = 8088;
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

    networking.networkmanager.enable = true;
    
    # Don't create the connection profile declaratively - it will be created at runtime
    # when we detect actual WiFi hardware. This prevents errors when hardware doesn't exist.

    systemd.services.easyos-hotspot = {
      description = "EASYOS Wi-Fi Hotspot Activator";
      wantedBy = [ "multi-user.target" ];
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      
      # Only run on installed system, not in live ISO
      # We gate on a marker file created by the installer: /etc/easy/installed
      unitConfig = {
        ConditionPathExists = [ "/etc/easy/installed" ];
      };
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      
      script = ''
        # Additional check: ensure we're on an installed system
        if [ ! -f /etc/easy/installed ]; then
          echo "Not running on installed system - skipping hotspot setup"
          exit 0
        fi
        
        # Wait a bit for NetworkManager to be fully ready
        sleep 3
        
        # Try to find a wifi interface
        WIFI_IFACE=$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device 2>/dev/null | ${pkgs.gnugrep}/bin/grep ':wifi$' | ${pkgs.coreutils}/bin/cut -d: -f1 | ${pkgs.coreutils}/bin/head -1 || true)
        
        if [ -z "$WIFI_IFACE" ]; then
          echo "No WiFi interface found - hotspot disabled, Ethernet available for setup"
          exit 0
        fi
        
        echo "Found WiFi interface: $WIFI_IFACE"
        
        # Delete any existing hotspot connection
        ${pkgs.networkmanager}/bin/nmcli connection delete easyos-hotspot 2>/dev/null || true
        
        # Create the hotspot connection dynamically with detected interface
        ${pkgs.networkmanager}/bin/nmcli connection add \
          type wifi \
          ifname "$WIFI_IFACE" \
          con-name easyos-hotspot \
          autoconnect yes \
          ssid "${ssid}" \
          802-11-wireless.mode ap \
          802-11-wireless.band bg \
          ipv4.method shared \
          ipv4.addresses 10.42.0.1/24 \
          ipv6.method disabled \
          wifi-sec.key-mgmt wpa-psk \
          wifi-sec.psk "${psk}"
        
        # Activate the connection
        ${pkgs.networkmanager}/bin/nmcli connection up easyos-hotspot || {
          echo "Failed to start hotspot on $WIFI_IFACE - hardware may not support AP mode"
          exit 0
        }
        
        echo "Hotspot 'easyos-hotspot' activated successfully on $WIFI_IFACE"
      '';
      
      preStop = ''
        ${pkgs.networkmanager}/bin/nmcli connection down easyos-hotspot 2>/dev/null || true
        ${pkgs.networkmanager}/bin/nmcli connection delete easyos-hotspot 2>/dev/null || true
      '';
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      
      virtualHosts."_" = {
        default = true;
        listen = [ 
          { addr = "0.0.0.0"; port = 80; }
          { addr = "10.42.0.1"; port = 80; }
        ];
        
        locations."/" = {
          return = "302 http://10.42.0.1:${toString captivePort}/";
        };
        
        locations."/generate_204" = { 
          return = "302 http://10.42.0.1:${toString captivePort}/"; 
        };
        locations."/gen_204" = { 
          return = "302 http://10.42.0.1:${toString captivePort}/"; 
        };
        locations."/hotspot-detect.html" = { 
          return = "302 http://10.42.0.1:${toString captivePort}/"; 
        };
        locations."/connectivity-check.html" = { 
          return = "302 http://10.42.0.1:${toString captivePort}/"; 
        };
        locations."/ncsi.txt" = { 
          return = "302 http://10.42.0.1:${toString captivePort}/"; 
        };
      };
    };

  networking.firewall.allowedTCPPorts = lib.mkAfter [ 80 ];
  };
}
