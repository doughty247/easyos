{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  
  netCfg = if (cfgJSON ? network) then cfgJSON.network else {};
  
  # QoS configuration
  qosEnabled = if (netCfg ? qosEnabled) then netCfg.qosEnabled else true;
  qosDownloadMbps = if (netCfg ? qosDownloadMbps) then netCfg.qosDownloadMbps else "100";
  qosUploadMbps = if (netCfg ? qosUploadMbps) then netCfg.qosUploadMbps else "20";
  
  # Auto-detect WAN speed on boot
  qosAutoDetect = if (netCfg ? qosAutoDetect) then netCfg.qosAutoDetect else false;
in {
  options.easyos.networkPerformance.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable network performance tuning and QoS system-wide";
  };

  config = lib.mkIf config.easyos.networkPerformance.enable {
    # TCP/IP stack tuning for high performance and low latency
    boot.kernel.sysctl = {
      # Enable IP forwarding (needed for routing/NAT)
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 0;
      
      # TCP buffer sizing for high-speed networks
      "net.core.rmem_max" = 134217728;  # 128MB receive buffer max
      "net.core.wmem_max" = 134217728;  # 128MB send buffer max
      "net.core.rmem_default" = 16777216;  # 16MB default receive
      "net.core.wmem_default" = 16777216;  # 16MB default send
      "net.ipv4.tcp_rmem" = "4096 87380 67108864";  # min, default, max read
      "net.ipv4.tcp_wmem" = "4096 65536 67108864";  # min, default, max write
      
      # Network device queue depth
      "net.core.netdev_max_backlog" = 5000;
      "net.core.netdev_budget" = 600;  # Packets processed per NAPI poll
      "net.core.netdev_budget_usecs" = 8000;  # Time per NAPI poll (8ms)
      
      # TCP Fast Open for reduced connection latency
      "net.ipv4.tcp_fastopen" = 3;  # Enable for client and server
      
      # Low latency TCP tuning
      "net.ipv4.tcp_low_latency" = 1;
      "net.ipv4.tcp_mtu_probing" = 1;  # Auto MTU discovery
      "net.ipv4.tcp_timestamps" = 1;  # Better RTT estimation
      "net.ipv4.tcp_sack" = 1;  # Selective ACK
      "net.ipv4.tcp_fack" = 1;  # Forward ACK
      
      # Reduce TIME_WAIT socket reuse delay
      "net.ipv4.tcp_fin_timeout" = 15;
      "net.ipv4.tcp_tw_reuse" = 1;
      
      # TCP window scaling for high-bandwidth connections
      "net.ipv4.tcp_window_scaling" = 1;
      
      # BBR congestion control (better than cubic)
      "net.core.default_qdisc" = "fq";  # Fair queue required for BBR
      "net.ipv4.tcp_congestion_control" = "bbr";
      
      # Disable IPv6 if not used (reduces overhead)
      "net.ipv6.conf.all.disable_ipv6" = 0;  # Keep enabled by default
      "net.ipv6.conf.default.disable_ipv6" = 0;
    };
    
    # Load performance-related kernel modules
    boot.kernelModules = [ 
      "tcp_bbr"           # BBR congestion control
      "sch_cake"          # CAKE qdisc for QoS
      "sch_fq"            # Fair queue for BBR
      "sch_fq_codel"      # FQ-CoDel (fallback)
      "ifb"               # Intermediate Functional Block for ingress shaping
    ];
    
    # System-wide QoS service (applies to primary WAN interface)
    systemd.services.easyos-qos = lib.mkIf qosEnabled {
      description = "EASYOS System-Wide QoS (CAKE)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      
      # Only run on installed system
      unitConfig = {
        ConditionPathExists = [ "/etc/easy/installed" ];
      };
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      
      script = ''
        # Wait for network to be fully up
        sleep 5
        
        # Determine QoS bandwidth settings
        DOWNLOAD_MBPS="${qosDownloadMbps}"
        UPLOAD_MBPS="${qosUploadMbps}"
        
        ${lib.optionalString qosAutoDetect ''
          # Check if network-autodiscovery has profiled this network
          QOS_CONFIG="/etc/easy/qos-current.json"
          if [ -f "$QOS_CONFIG" ]; then
            echo "Using auto-detected QoS settings from network profile"
            AUTO_DOWNLOAD=$(${pkgs.jq}/bin/jq -r '.download' "$QOS_CONFIG" 2>/dev/null || echo "")
            AUTO_UPLOAD=$(${pkgs.jq}/bin/jq -r '.upload' "$QOS_CONFIG" 2>/dev/null || echo "")
            
            if [ -n "$AUTO_DOWNLOAD" ] && [ -n "$AUTO_UPLOAD" ]; then
              DOWNLOAD_MBPS="$AUTO_DOWNLOAD"
              UPLOAD_MBPS="$AUTO_UPLOAD"
              echo "  Download: $DOWNLOAD_MBPS Mbps"
              echo "  Upload: $UPLOAD_MBPS Mbps"
            else
              echo "Auto-detect enabled but no profile yet - using config defaults"
            fi
          else
            echo "Auto-detect enabled - waiting for network profiler to complete"
            echo "Using config defaults temporarily"
          fi
        ''}
        
        # Find primary WAN interface (has default route)
        WAN_IFACE=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gnugrep}/bin/grep '^default' | ${pkgs.gawk}/bin/awk '{print $5}' | ${pkgs.coreutils}/bin/head -1 || true)
        
        if [ -z "$WAN_IFACE" ]; then
          echo "No WAN interface found - QoS not configured"
          exit 0
        fi
        
        echo "Setting up CAKE QoS on $WAN_IFACE (download: ''${DOWNLOAD_MBPS}Mbps, upload: ''${UPLOAD_MBPS}Mbps)"
        
        # Upload shaping (egress on WAN interface)
        ${pkgs.iproute2}/bin/tc qdisc add dev "$WAN_IFACE" root cake \
          bandwidth ''${UPLOAD_MBPS}mbit \
          diffserv4 \
          dual-srchost \
          nat \
          wash \
          ack-filter-aggressive \
          rtt 100ms \
          raw 2>/dev/null || {
            echo "WARNING: CAKE QoS setup failed on $WAN_IFACE (kernel module may not be loaded)"
            exit 0
          }
        
        # Download shaping (ingress on WAN - requires IFB)
        # Create intermediate functional block device for ingress shaping
        ${pkgs.iproute2}/bin/ip link add name ifb4wan type ifb 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link set ifb4wan up
        
        # Redirect ingress traffic to IFB
        ${pkgs.iproute2}/bin/tc qdisc add dev "$WAN_IFACE" handle ffff: ingress 2>/dev/null || true
        ${pkgs.iproute2}/bin/tc filter add dev "$WAN_IFACE" parent ffff: \
          protocol all \
          u32 match u32 0 0 \
          action mirred egress redirect dev ifb4wan 2>/dev/null || true
        
        # Apply CAKE to IFB (this shapes download)
        ${pkgs.iproute2}/bin/tc qdisc add dev ifb4wan root cake \
          bandwidth ''${DOWNLOAD_MBPS}mbit \
          diffserv4 \
          dual-dsthost \
          nat \
          wash \
          ingress \
          rtt 100ms \
          raw 2>/dev/null || {
            echo "WARNING: CAKE download shaping failed"
          }
        
        echo "CAKE QoS active on $WAN_IFACE: bufferbloat control enabled system-wide"
      '';
      
      preStop = ''
        WAN_IFACE=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gnugrep}/bin/grep '^default' | ${pkgs.gawk}/bin/awk '{print $5}' | ${pkgs.coreutils}/bin/head -1 || true)
        if [ -n "$WAN_IFACE" ]; then
          echo "Removing CAKE QoS from $WAN_IFACE"
          ${pkgs.iproute2}/bin/tc qdisc del dev "$WAN_IFACE" root 2>/dev/null || true
          ${pkgs.iproute2}/bin/tc qdisc del dev "$WAN_IFACE" ingress 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip link set ifb4wan down 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip link del ifb4wan 2>/dev/null || true
        fi
      '';
    };
    
    # Install performance monitoring tools
    environment.systemPackages = with pkgs; [
      iproute2
      ethtool
      iperf3
      speedtest-cli
    ];
  };
}
