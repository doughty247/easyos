{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  
  netCfg = if (cfgJSON ? network) then cfgJSON.network else {};
  qosAutoDetect = if (netCfg ? qosAutoDetect) then netCfg.qosAutoDetect else false;
in {
  options.easyos.networkAutodiscovery.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable automatic network speed profiling per network";
  };

  config = lib.mkIf (config.easyos.networkAutodiscovery.enable && qosAutoDetect) {
    
    # Network profile database stored in /var/lib/easyos/network-profiles.json
    # Structure: { "<gateway_mac>_<ssid>": { "download": 100, "upload": 20, "samples": 2, "last_test": "2025-10-29T12:00:00Z" } }
    
    systemd.services.easyos-network-profiler = {
      description = "EASYOS Network Speed Profiler";
      
      # Triggered by network-online.target, but with a delay to ensure stability
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      
      # Only run on installed system
      unitConfig = {
        ConditionPathExists = [ "/etc/easy/installed" ];
      };
      
      serviceConfig = {
        Type = "oneshot";
        # Don't restart automatically - timer will trigger us
        Restart = "no";
      };
      
      script = ''
        set -euo pipefail
        
        PROFILE_DIR="/var/lib/easyos"
        PROFILE_DB="$PROFILE_DIR/network-profiles.json"
        QOS_CONFIG="/etc/easy/qos-current.json"
        
        mkdir -p "$PROFILE_DIR"
        
        # Wait for network to stabilize
        echo "Waiting for network to stabilize..."
        sleep 10
        
        # Identify current network by gateway MAC and SSID (if WiFi)
        GATEWAY_IP=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gnugrep}/bin/grep '^default' | ${pkgs.gawk}/bin/awk '{print $3}' | ${pkgs.coreutils}/bin/head -1 || echo "")
        
        if [ -z "$GATEWAY_IP" ]; then
          echo "No default gateway found - skipping network profiling"
          exit 0
        fi
        
        # Get gateway MAC address
        GATEWAY_MAC=$(${pkgs.iproute2}/bin/ip neigh show "$GATEWAY_IP" | ${pkgs.gawk}/bin/awk '{print $5}' | ${pkgs.coreutils}/bin/head -1 || echo "unknown")
        
        # Check if we're on WiFi and get SSID
        WIFI_IFACE=$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device 2>/dev/null | ${pkgs.gnugrep}/bin/grep ':wifi$' | ${pkgs.coreutils}/bin/cut -d: -f1 | ${pkgs.coreutils}/bin/head -1 || echo "")
        SSID=""
        if [ -n "$WIFI_IFACE" ]; then
          SSID=$(${pkgs.networkmanager}/bin/nmcli -t -f active,ssid dev wifi 2>/dev/null | ${pkgs.gnugrep}/bin/grep '^yes:' | ${pkgs.coreutils}/bin/cut -d: -f2 || echo "")
        fi
        
        # Create network identifier: MAC_SSID (or MAC if no SSID)
        NETWORK_ID="''${GATEWAY_MAC}_''${SSID}"
        
        echo "Network identified: $NETWORK_ID"
        echo "  Gateway: $GATEWAY_IP ($GATEWAY_MAC)"
        [ -n "$SSID" ] && echo "  SSID: $SSID"
        
        # Initialize profile database if not exists
        if [ ! -f "$PROFILE_DB" ]; then
          echo '{}' > "$PROFILE_DB"
        fi
        
        # Load existing profiles
        PROFILES=$(${pkgs.jq}/bin/jq -r '.' "$PROFILE_DB" 2>/dev/null || echo '{}')
        
        # Check if this network has been profiled
        EXISTING=$(echo "$PROFILES" | ${pkgs.jq}/bin/jq -r --arg net "$NETWORK_ID" '.[$net] // empty')
        SAMPLE_COUNT=0
        
        if [ -n "$EXISTING" ]; then
          SAMPLE_COUNT=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.samples // 0')
          echo "Network already profiled with $SAMPLE_COUNT samples"
        else
          echo "New network detected - starting profiling"
        fi
        
        # Only run speedtest if we have < 2 samples (initial + 12h retest)
        if [ "$SAMPLE_COUNT" -lt 2 ]; then
          echo "Running speedtest... (this may take 30-60 seconds)"
          
          # Run speedtest-cli and parse results
          SPEEDTEST_OUTPUT=$(${pkgs.speedtest-cli}/bin/speedtest-cli --simple 2>&1 || echo "FAILED")
          
          if echo "$SPEEDTEST_OUTPUT" | ${pkgs.gnugrep}/bin/grep -q "FAILED"; then
            echo "Speedtest failed - will retry later"
            exit 0
          fi
          
          # Parse output: "Download: 123.45 Mbit/s" and "Upload: 45.67 Mbit/s"
          DOWNLOAD=$(echo "$SPEEDTEST_OUTPUT" | ${pkgs.gnugrep}/bin/grep "Download:" | ${pkgs.gawk}/bin/awk '{print $2}')
          UPLOAD=$(echo "$SPEEDTEST_OUTPUT" | ${pkgs.gnugrep}/bin/grep "Upload:" | ${pkgs.gawk}/bin/awk '{print $2}')
          
          echo "Speedtest results: $DOWNLOAD Mbps down, $UPLOAD Mbps up"
          
          # Apply 95% safety margin for QoS (recommended for CAKE)
          DOWNLOAD_95=$(echo "$DOWNLOAD * 0.95" | ${pkgs.bc}/bin/bc | ${pkgs.coreutils}/bin/cut -d. -f1)
          UPLOAD_95=$(echo "$UPLOAD * 0.95" | ${pkgs.bc}/bin/bc | ${pkgs.coreutils}/bin/cut -d. -f1)
          
          # Update profile database
          CURRENT_TIME=$(${pkgs.coreutils}/bin/date -Iseconds)
          
          if [ "$SAMPLE_COUNT" -eq 0 ]; then
            # First sample - store raw values
            NEW_PROFILE=$(${pkgs.jq}/bin/jq -n \
              --arg dl "$DOWNLOAD_95" \
              --arg ul "$UPLOAD_95" \
              --arg time "$CURRENT_TIME" \
              '{download: ($dl | tonumber), upload: ($ul | tonumber), samples: 1, first_test: $time, last_test: $time}')
          else
            # Second sample - calculate average
            OLD_DOWNLOAD=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.download')
            OLD_UPLOAD=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.upload')
            FIRST_TEST=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.first_test')
            
            AVG_DOWNLOAD=$(echo "($OLD_DOWNLOAD + $DOWNLOAD_95) / 2" | ${pkgs.bc}/bin/bc | ${pkgs.coreutils}/bin/cut -d. -f1)
            AVG_UPLOAD=$(echo "($OLD_UPLOAD + $UPLOAD_95) / 2" | ${pkgs.bc}/bin/bc | ${pkgs.coreutils}/bin/cut -d. -f1)
            
            echo "Averaging with previous sample: $AVG_DOWNLOAD Mbps down, $AVG_UPLOAD Mbps up"
            
            NEW_PROFILE=$(${pkgs.jq}/bin/jq -n \
              --arg dl "$AVG_DOWNLOAD" \
              --arg ul "$AVG_UPLOAD" \
              --arg first "$FIRST_TEST" \
              --arg time "$CURRENT_TIME" \
              '{download: ($dl | tonumber), upload: ($ul | tonumber), samples: 2, first_test: $first, last_test: $time}')
          fi
          
          # Update profile database
          UPDATED_PROFILES=$(echo "$PROFILES" | ${pkgs.jq}/bin/jq \
            --arg net "$NETWORK_ID" \
            --argjson profile "$NEW_PROFILE" \
            '.[$net] = $profile')
          
          echo "$UPDATED_PROFILES" > "$PROFILE_DB"
          chmod 644 "$PROFILE_DB"
          
          # Write current QoS settings for network-performance module to pick up
          echo "$NEW_PROFILE" | ${pkgs.jq}/bin/jq '{download, upload}' > "$QOS_CONFIG"
          chmod 644 "$QOS_CONFIG"
          
          echo "Network profile updated. QoS will be applied."
          
          # Restart QoS service to apply new settings
          ${pkgs.systemd}/bin/systemctl restart easyos-qos.service || true
          
          # If this was the first sample, schedule a retest in 12 hours
          if [ "$SAMPLE_COUNT" -eq 0 ]; then
            echo "Scheduling second speedtest in 12 hours for averaging..."
            ${pkgs.systemd}/bin/systemd-run --on-active=12h --unit=easyos-network-profiler-retest \
              ${pkgs.systemd}/bin/systemctl start easyos-network-profiler.service
          fi
        else
          echo "Network fully profiled (2 samples). Using cached values."
          
          # Apply cached settings
          CACHED_DOWNLOAD=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.download')
          CACHED_UPLOAD=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.upload')
          
          echo "Using cached QoS: $CACHED_DOWNLOAD Mbps down, $CACHED_UPLOAD Mbps up"
          
          echo "$EXISTING" | ${pkgs.jq}/bin/jq '{download, upload}' > "$QOS_CONFIG"
          chmod 644 "$QOS_CONFIG"
          
          # Restart QoS service to apply cached settings
          ${pkgs.systemd}/bin/systemctl restart easyos-qos.service || true
        fi
      '';
    };
    
    # Trigger profiler when network comes online
    systemd.services.easyos-network-profiler-trigger = {
      description = "Trigger Network Profiler on Network Change";
      wantedBy = [ "network-online.target" ];
      after = [ "network-online.target" ];
      
      unitConfig = {
        ConditionPathExists = [ "/etc/easy/installed" ];
      };
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };
      
      script = ''
        # Give network time to stabilize, then trigger profiler
        sleep 5
        ${pkgs.systemd}/bin/systemctl start easyos-network-profiler.service || true
      '';
    };
    
    # Install required tools
    environment.systemPackages = with pkgs; [
      speedtest-cli
      jq
      bc
    ];
  };
}
