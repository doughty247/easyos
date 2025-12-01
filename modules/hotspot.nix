{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  mode = if (cfgJSON ? mode) then cfgJSON.mode else "first-run";
  netCfg = if (cfgJSON ? network) then cfgJSON.network else {};
  ssid = if (netCfg ? ssid) then netCfg.ssid else "easeOS-Setup";
  greenhouseSSID = if (netCfg ? greenhouseSSID) then netCfg.greenhouseSSID else "easeOS-Greenhouse";
  psk  = if (netCfg ? psk) then netCfg.psk else "changeme-strong-pass";
  
  # Hotspot network configuration
  hotspotSubnet = if (netCfg ? hotspotSubnet) then netCfg.hotspotSubnet else "10.42.0.0/24";
  hotspotIP = if (netCfg ? hotspotIP) then netCfg.hotspotIP else "10.42.0.1";
  hotspotDHCPStart = if (netCfg ? hotspotDHCPStart) then netCfg.hotspotDHCPStart else "10.42.0.10";
  hotspotDHCPEnd = if (netCfg ? hotspotDHCPEnd) then netCfg.hotspotDHCPEnd else "10.42.0.250";
  wifiChannel = if (netCfg ? wifiChannel) then netCfg.wifiChannel else "6";
  clientIsolation = if (netCfg ? clientIsolation) then netCfg.clientIsolation else true;
  
  # Greenhouse mode configuration (emergency hotspot when internet goes down)
  greenhouseEnabled = if (netCfg ? greenhouseEnabled) then netCfg.greenhouseEnabled else true;  # Auto-Greenhouse on by default
  greenhouseCheckInterval = if (netCfg ? greenhouseCheckInterval) then netCfg.greenhouseCheckInterval else 30;  # seconds between checks
  greenhouseFailThreshold = if (netCfg ? greenhouseFailThreshold) then netCfg.greenhouseFailThreshold else 3;  # failures before Greenhouse
  greenhouseCheckHost = if (netCfg ? greenhouseCheckHost) then netCfg.greenhouseCheckHost else "1.1.1.1";  # ping target
  
  # QoS configuration (CAKE algorithm for bufferbloat control)
  qosEnabled = if (netCfg ? qosEnabled) then netCfg.qosEnabled else true;
  qosDownloadMbps = if (netCfg ? qosDownloadMbps) then netCfg.qosDownloadMbps else "100";  # Adjust to your WAN speed
  qosUploadMbps = if (netCfg ? qosUploadMbps) then netCfg.qosUploadMbps else "20";  # Adjust to your WAN speed
  
  # WiFi performance tuning
  wifiPowerSave = if (netCfg ? wifiPowerSave) then netCfg.wifiPowerSave else false;  # Disabled by default for speed
  # Walled garden: disable WAN access from hotspot clients unless enabled
  allowHotspotWAN = if (netCfg ? hotspotAllowWAN) then netCfg.hotspotAllowWAN else false;

  # Hotspot activates for: first-run, guest, OR greenhouse mode
  hotspotEnabled = (mode == "first-run") || (mode == "guest") || (mode == "greenhouse");
  captivePort = 1234;
  
  # ISO mode detection: check for marker file created by flake.nix ISO configuration
  isISOMode = builtins.pathExists "/etc/easy/iso-mode";
in {
  options.easyos.hotspot.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable hotspot/guest mode automation (driven by JSON 'mode').";
  };

  config = lib.mkMerge [
    # Always open webui port regardless of hotspot state - use mkDefault so it can be extended
    { 
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ 1234 ];
      };
    }
    
    # Conditional hotspot configuration
    (lib.mkIf (config.easyos.hotspot.enable && hotspotEnabled) {
    assertions = [
      { assertion = ssid != null; message = "hotspot: SSID must be set."; }
    ];

    # Network performance tuning is handled by network-performance.nix module
    # This module only handles hotspot-specific configuration
    
    networking.networkmanager.enable = true;
    
    # Don't create the connection profile declaratively - it will be created at runtime
    # when we detect actual WiFi hardware. This prevents errors when hardware doesn't exist.

    systemd.services.easyos-hotspot = {
      description = "easeOS Wi-Fi Hotspot Activator";
      wantedBy = [ "multi-user.target" ];
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      
      # Run on EITHER installed system OR live ISO (for setup wizard)
      # The script checks for the markers internally - no systemd condition needed
      # This allows the service to start and handle both cases gracefully
      
      path = [ pkgs.util-linux pkgs.iw ];  # For rfkill and iw commands
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      
      script = ''
        set -x  # Debug: show all commands
        echo "=== easyos-hotspot service starting ==="
        echo "Date: $(date)"
        
        # Debug: Show what files exist
        echo "Checking marker files..."
        ls -la /etc/easy/ 2>&1 || echo "/etc/easy/ not found"
        
        # Check we're on either installed system or ISO mode
        if [ ! -f /etc/easy/installed ] && [ ! -f /etc/easy/iso-mode ]; then
          echo "ERROR: Neither /etc/easy/installed nor /etc/easy/iso-mode exists"
          echo "Not running on installed system or ISO - skipping hotspot setup"
          exit 0
        fi
        
        IS_ISO=false
        if [ -f /etc/easy/iso-mode ]; then
          IS_ISO=true
          echo "Running in ISO mode - starting captive portal for web-based setup"
          
          # Ensure WiFi radio is on and wait for it
          echo "Enabling WiFi radio..."
          ${pkgs.networkmanager}/bin/nmcli radio wifi on 2>/dev/null || true
          sleep 2
          
          # Unblock WiFi if rfkill blocked it
          if command -v rfkill >/dev/null 2>&1; then
            rfkill unblock wifi 2>/dev/null || true
            rfkill unblock all 2>/dev/null || true
          fi
          sleep 1
        fi
        
        # Wait for NetworkManager to be fully ready
        echo "Waiting for NetworkManager..."
        sleep 3
        
        # Try to find a wifi interface
        WIFI_IFACE=$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device 2>/dev/null | ${pkgs.gnugrep}/bin/grep ':wifi$' | ${pkgs.coreutils}/bin/cut -d: -f1 | ${pkgs.coreutils}/bin/head -1 || true)
        
        if [ -z "$WIFI_IFACE" ]; then
          echo "No WiFi interface found - hotspot disabled, Ethernet available for setup"
          exit 0
        fi
        
        echo "Found WiFi interface: $WIFI_IFACE"
        
        # Show current WiFi state for debugging
        echo "Current WiFi device state:"
        ${pkgs.networkmanager}/bin/nmcli device show "$WIFI_IFACE" 2>&1 || true
        
        # Disconnect any existing connection on this interface
        echo "Disconnecting any existing connection on $WIFI_IFACE..."
        ${pkgs.networkmanager}/bin/nmcli device disconnect "$WIFI_IFACE" 2>/dev/null || true
        sleep 1
        
        # Disable WiFi power saving for maximum performance and low latency
        ${lib.optionalString (!wifiPowerSave) ''
          echo "Disabling WiFi power management on $WIFI_IFACE for optimal performance"
          ${pkgs.iw}/bin/iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
          # Also set via sysfs if available
          if [ -e "/sys/class/net/$WIFI_IFACE/device/power_save" ]; then
            echo 0 > "/sys/class/net/$WIFI_IFACE/device/power_save" 2>/dev/null || true
          fi
        ''}
        
        # Delete any existing hotspot connection
        ${pkgs.networkmanager}/bin/nmcli connection delete easyos-hotspot 2>/dev/null || true
        
        # Create the hotspot connection dynamically with detected interface
        echo "Creating hotspot connection..."
        if ! ${pkgs.networkmanager}/bin/nmcli connection add \
          type wifi \
          ifname "$WIFI_IFACE" \
          con-name easyos-hotspot \
          autoconnect no \
          ssid "${ssid}" \
          802-11-wireless.mode ap \
          802-11-wireless.band bg \
          802-11-wireless.channel ${wifiChannel} \
          802-11-wireless.hidden no \
          ipv4.method shared \
          ipv4.addresses ${hotspotIP}/24 \
          ipv6.method disabled \
          wifi-sec.key-mgmt none 2>&1; then
          echo "ERROR: Failed to create hotspot connection!"
          echo "Trying alternative method with nmcli device wifi hotspot..."
          
          # Alternative: Use the simpler hotspot command
          ${pkgs.networkmanager}/bin/nmcli device wifi hotspot ifname "$WIFI_IFACE" ssid "${ssid}" password "" 2>&1 || {
            echo "Alternative method also failed"
            exit 1
          }
        fi
        
        echo "Connection created, verifying..."
        ${pkgs.networkmanager}/bin/nmcli connection show easyos-hotspot 2>&1 | head -5 || echo "Connection not found!"
        
        # Small delay to let NM process the new connection
        sleep 1
        
        # Activate the connection with retries - specify ifname explicitly!
        echo "Activating hotspot on $WIFI_IFACE..."
        HOTSPOT_UP=false
        for attempt in 1 2 3; do
          echo "Activation attempt $attempt/3..."
          if ${pkgs.networkmanager}/bin/nmcli connection up easyos-hotspot ifname "$WIFI_IFACE" 2>&1; then
            HOTSPOT_UP=true
            break
          fi
          echo "Attempt $attempt failed, waiting before retry..."
          sleep 3
        done
        
        if [ "$HOTSPOT_UP" = "false" ]; then
          echo "ERROR: Failed to start hotspot on $WIFI_IFACE after 3 attempts"
          echo "Trying alternative hotspot method..."
          
          # Try the simpler built-in hotspot command as fallback
          if ${pkgs.networkmanager}/bin/nmcli device wifi hotspot ifname "$WIFI_IFACE" con-name easyos-hotspot ssid "${ssid}" 2>&1; then
            echo "Alternative hotspot method succeeded!"
            HOTSPOT_UP=true
          else
            echo "Alternative method also failed."
            echo "Checking device capabilities..."
            ${pkgs.iw}/bin/iw phy 2>/dev/null | grep -A 10 "Supported interface modes" || true
            echo ""
            echo "Current device state:"
            ${pkgs.networkmanager}/bin/nmcli device show "$WIFI_IFACE" 2>/dev/null || true
            exit 0
          fi
        fi
        
        echo "Hotspot 'easyos-hotspot' activated successfully on $WIFI_IFACE"
        
        # Set up NAT/masquerading for hotspot clients only if allowed
        if [ "${toString allowHotspotWAN}" = "true" ]; then
          # Find the default route interface (WAN)
          WAN_IFACE=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gnugrep}/bin/grep '^default' | ${pkgs.gawk}/bin/awk '{print $5}' | ${pkgs.coreutils}/bin/head -1 || true)
          if [ -n "$WAN_IFACE" ] && [ "$WAN_IFACE" != "$WIFI_IFACE" ]; then
            echo "Setting up NAT: $WIFI_IFACE (hotspot) -> $WAN_IFACE (WAN)"
            # NAT rule: masquerade traffic from hotspot subnet going to WAN
            ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${hotspotSubnet} -o "$WAN_IFACE" -j MASQUERADE
            # Allow forwarding from hotspot to WAN
            ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o "$WAN_IFACE" -j ACCEPT
            ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WAN_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
          else
            echo "No WAN interface found or WAN is same as WiFi - NAT not configured"
          fi
        else
          echo "WAN access for hotspot clients is disabled by policy"
        fi
        
        # Limit captive portal to a single concurrent connection from hotspot subnet
        ${pkgs.iptables}/bin/iptables -A INPUT -i "$WIFI_IFACE" -p tcp --dport ${toString captivePort} -m connlimit --connlimit-above 1 --connlimit-mask 0 -j REJECT || true

  # DNS hijacking for captive portal detection
        # Redirect all DNS queries from hotspot clients to our local DNS
        ${pkgs.iptables}/bin/iptables -t nat -A PREROUTING -i "$WIFI_IFACE" -p udp --dport 53 -j DNAT --to ${hotspotIP}:53
        ${pkgs.iptables}/bin/iptables -t nat -A PREROUTING -i "$WIFI_IFACE" -p tcp --dport 53 -j DNAT --to ${hotspotIP}:53
        
        # Note: System-wide CAKE QoS is handled by network-performance.nix module
        # It applies to all traffic including hotspot
      '';
      
      preStop = ''
        # QoS cleanup is handled by network-performance.nix module
        
        # Clean up iptables rules
        WIFI_IFACE=$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device 2>/dev/null | ${pkgs.gnugrep}/bin/grep ':wifi$' | ${pkgs.coreutils}/bin/cut -d: -f1 | ${pkgs.coreutils}/bin/head -1 || true)
        WAN_IFACE=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gnugrep}/bin/grep '^default' | ${pkgs.gawk}/bin/awk '{print $5}' | ${pkgs.coreutils}/bin/head -1 || true)
        if [ -n "$WIFI_IFACE" ]; then
          ${pkgs.iptables}/bin/iptables -D INPUT -i "$WIFI_IFACE" -p tcp --dport ${toString captivePort} -m connlimit --connlimit-above 1 --connlimit-mask 0 -j REJECT 2>/dev/null || true
          ${pkgs.iptables}/bin/iptables -t nat -D PREROUTING -i "$WIFI_IFACE" -p udp --dport 53 -j DNAT --to ${hotspotIP}:53 2>/dev/null || true
          ${pkgs.iptables}/bin/iptables -t nat -D PREROUTING -i "$WIFI_IFACE" -p tcp --dport 53 -j DNAT --to ${hotspotIP}:53 2>/dev/null || true
          
          if [ -n "$WAN_IFACE" ]; then
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${hotspotSubnet} -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -D FORWARD -i "$WIFI_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -D FORWARD -i "$WAN_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
          fi
        fi
        
        ${pkgs.networkmanager}/bin/nmcli connection down easyos-hotspot 2>/dev/null || true
        ${pkgs.networkmanager}/bin/nmcli connection delete easyos-hotspot 2>/dev/null || true
      '';
    };

    # NetworkManager's 'shared' mode already runs dnsmasq automatically
    # We don't need to enable a separate dnsmasq service - it handles DHCP/DNS for us
    # NetworkManager spawns dnsmasq only when the hotspot connection is active
    # This prevents the boot-time dnsmasq failures seen in the logs

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      
      virtualHosts."_" = {
        default = true;
        # Bind ONLY to hotspot interface to avoid exposing captive portal on WAN/LAN
        listen = [ 
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

    # Firewall configuration for hotspot
    # Note: Port 1234 (webui) is opened unconditionally at the top of this file
  networking.firewall = {
      # Restrict other ports to hotspot subnet only via iptables rules below
      allowedUDPPorts = [ ];
      # Explicitly include webui port to ensure it's always open
      allowedTCPPorts = [ 1234 ];

      extraCommands = ''
        # Allow webui port from ANY source (not just hotspot subnet)
        # This ensures VM testing and external access work
        iptables -A INPUT -p tcp --dport ${toString captivePort} -j ACCEPT
        
        # Allow DNS from hotspot clients to this host
        iptables -A INPUT -s ${hotspotSubnet} -p udp --dport 53 -j ACCEPT
        iptables -A INPUT -s ${hotspotSubnet} -p tcp --dport 53 -j ACCEPT
        # Allow DHCP requests from hotspot clients
        iptables -A INPUT -s ${hotspotSubnet} -p udp --dport 67 -j ACCEPT
        # Allow captive portal HTTP from hotspot clients only
        iptables -A INPUT -s ${hotspotSubnet} -p tcp --dport 80 -j ACCEPT
        # Block mDNS from hotspot clients to avoid device discovery
        iptables -A INPUT -s ${hotspotSubnet} -p udp --dport 5353 -j DROP

        # Ensure forwarding policy and established allow
        iptables -P FORWARD DROP
        iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
      '';
      extraStopCommands = ''
        iptables -D INPUT -s ${hotspotSubnet} -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -s ${hotspotSubnet} -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -s ${hotspotSubnet} -p udp --dport 67 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -s ${hotspotSubnet} -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -s ${hotspotSubnet} -p tcp --dport ${toString captivePort} -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -s ${hotspotSubnet} -p udp --dport 5353 -j DROP 2>/dev/null || true
        iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
      '';
    };
    
    # Environment packages for hotspot management
    environment.systemPackages = with pkgs; [
      iptables
      iproute2
      iw  # For WiFi power management control
    ];
  })
  
  # Greenhouse Mode Watchdog - monitors internet and triggers emergency hotspot
  (lib.mkIf (config.easyos.hotspot.enable && greenhouseEnabled && mode == "normal") {
    systemd.services.easyos-greenhouse-watchdog = {
      description = "easeOS Greenhouse Mode - Internet Connectivity Monitor";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      
      unitConfig = {
        ConditionPathExists = [ "/etc/easy/installed" ];
      };
      
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "10";
      };
      
      path = with pkgs; [ coreutils gnugrep jq curl ];
      
      script = ''
        FAIL_COUNT=0
        GREENHOUSE_ACTIVE=false
        CONFIG_FILE="/etc/easy/config.json"
        GREENHOUSE_STATE_FILE="/run/easyos-greenhouse-active"
        
        echo "Greenhouse Watchdog started - monitoring connectivity to ${greenhouseCheckHost}"
        
        while true; do
          # Check internet connectivity
          if ${pkgs.iputils}/bin/ping -c 1 -W 5 ${greenhouseCheckHost} > /dev/null 2>&1; then
            # Internet is up
            if [ "$GREENHOUSE_ACTIVE" = "true" ]; then
              echo "Internet restored - deactivating Greenhouse"
              
              # Restore normal mode in config
              if [ -f "$CONFIG_FILE" ]; then
                ${pkgs.jq}/bin/jq '.mode = "normal"' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
              fi
              
              # Signal hotspot to stop
              rm -f "$GREENHOUSE_STATE_FILE"
              GREENHOUSE_ACTIVE=false
              
              # Restart hotspot service to deactivate
              systemctl restart easyos-hotspot.service 2>/dev/null || true
            fi
            FAIL_COUNT=0
          else
            # Internet is down
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "Connectivity check failed ($FAIL_COUNT/${toString greenhouseFailThreshold})"
            
            if [ "$FAIL_COUNT" -ge ${toString greenhouseFailThreshold} ] && [ "$GREENHOUSE_ACTIVE" = "false" ]; then
              echo "Internet down - activating Greenhouse mode"
              
              # Set Greenhouse mode in config
              if [ -f "$CONFIG_FILE" ]; then
                ${pkgs.jq}/bin/jq '.mode = "greenhouse"' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
              fi
              
              # Create state file with Greenhouse info for UI
              cat > "$GREENHOUSE_STATE_FILE" << EOF
{
  "active": true,
  "ssid": "${greenhouseSSID}",
  "ip": "${hotspotIP}",
  "port": ${toString captivePort},
  "since": "$(date -Iseconds)"
}
EOF
              
              GREENHOUSE_ACTIVE=true
              
              # Start emergency hotspot
              ${pkgs.networkmanager}/bin/nmcli connection delete easyos-greenhouse 2>/dev/null || true
              
              WIFI_IFACE=$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep ':wifi$' | cut -d: -f1 | head -1 || true)
              
              if [ -n "$WIFI_IFACE" ]; then
                echo "Starting Greenhouse hotspot on $WIFI_IFACE"
                ${pkgs.networkmanager}/bin/nmcli connection add \
                  type wifi \
                  ifname "$WIFI_IFACE" \
                  con-name easyos-greenhouse \
                  autoconnect no \
                  ssid "${greenhouseSSID}" \
                  802-11-wireless.mode ap \
                  802-11-wireless.band bg \
                  802-11-wireless.channel ${wifiChannel} \
                  ipv4.method shared \
                  ipv4.addresses ${hotspotIP}/24 \
                  ipv6.method disabled \
                  wifi-sec.key-mgmt none
                
                ${pkgs.networkmanager}/bin/nmcli connection up easyos-greenhouse || echo "Failed to start Greenhouse hotspot"
              else
                echo "No WiFi interface available for Greenhouse hotspot"
              fi
            fi
          fi
          
          sleep ${toString greenhouseCheckInterval}
        done
      '';
      
      preStop = ''
        # Clean up Greenhouse hotspot on service stop
        ${pkgs.networkmanager}/bin/nmcli connection down easyos-greenhouse 2>/dev/null || true
        ${pkgs.networkmanager}/bin/nmcli connection delete easyos-greenhouse 2>/dev/null || true
        rm -f /run/easyos-greenhouse-active
      '';
    };
  })
  ];
}