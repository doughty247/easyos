{ lib, pkgs, config, ... }:
let
  cfg = config.easyos.webui;
  
  # Python with cryptography for AES-256-GCM encryption
  pythonWithCrypto = pkgs.python3.withPackages (ps: [ ps.cryptography ]);
  
  # Store apps directory
  storeAppsDir = ../store/apps;
  
  # Apply script for config changes
  applyScript = ''
    #!/usr/bin/env bash
    set -euo pipefail
    LOG=/var/log/easyos-apply.log
    mkdir -p /var/log
    : > "$LOG"
    echo "[easyos] Applying configuration at $(date -Is)" | tee -a "$LOG"
    echo "Command: nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos" | tee -a "$LOG"
    
    if nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos 2>&1 | tee -a "$LOG"; then
      echo "[easyos] Apply completed successfully at $(date -Is)" | tee -a "$LOG"
      exit 0
    else
      RC=$?
      echo "[easyos] Apply failed with code $RC at $(date -Is)" | tee -a "$LOG"
      exit $RC
    fi
  '';
  
  # Web install script for ISO mode
  webinstallScript = ''
    #!/usr/bin/env bash
    set -euo pipefail
    
    PROGRESS_DIR="/tmp/easyos-install"
    PROGRESS_FILE="$PROGRESS_DIR/progress.json"
    CONFIG_FILE="/tmp/easyos-install-config.json"
    LOG_FILE="$PROGRESS_DIR/install.log"
    
    mkdir -p "$PROGRESS_DIR"
    
    update_progress() {
      local progress="$1"
      local stage="$2"
      local message="$3"
      local complete="''${4:-false}"
      local error="''${5:-null}"
      
      cat > "$PROGRESS_FILE" << EOF
    {
      "progress": $progress,
      "stage": "$stage",
      "message": "$message",
      "complete": $complete,
      "error": $error,
      "running": true
    }
    EOF
    }
    
    fail() {
      cat > "$PROGRESS_FILE" << EOF
    {
      "progress": 0,
      "stage": "error",
      "message": "$1",
      "complete": false,
      "error": "$1",
      "running": false
    }
    EOF
      echo "[ERROR] $1" | tee -a "$LOG_FILE"
      exit 1
    }
    
    echo "[INSTALL] Starting installation at $(date)" | tee "$LOG_FILE"
    
    # Load config
    if [ ! -f "$CONFIG_FILE" ]; then
      fail "Installation config not found"
    fi
    
    DRIVE=$(jq -r '.drive // empty' "$CONFIG_FILE")
    ENCRYPT=$(jq -r '.encrypt // false' "$CONFIG_FILE")
    USERNAME=$(jq -r '.username // empty' "$CONFIG_FILE")
    HOSTNAME=$(jq -r '.hostname // "easyos"' "$CONFIG_FILE")
    WIFI_SSID=$(jq -r '.wifiSSID // empty' "$CONFIG_FILE")
    
    if [ -z "$DRIVE" ]; then
      fail "No target drive specified"
    fi
    
    if [ -z "$USERNAME" ]; then
      fail "No username specified"
    fi
    
    # Get password hash
    if [ ! -f "/tmp/easyos-password-hash" ]; then
      fail "Password hash not found"
    fi
    PASSWORD_HASH=$(cat /tmp/easyos-password-hash)
    
    echo "[INSTALL] Drive: $DRIVE" | tee -a "$LOG_FILE"
    echo "[INSTALL] Encrypt: $ENCRYPT" | tee -a "$LOG_FILE"
    echo "[INSTALL] Username: $USERNAME" | tee -a "$LOG_FILE"
    echo "[INSTALL] Hostname: $HOSTNAME" | tee -a "$LOG_FILE"
    
    update_progress 5 "preparing" "Preparing installation..."
    sleep 1
    
    # Partitioning
    update_progress 10 "partitioning" "Creating partitions on $DRIVE..."
    
    # Wipe existing partitions
    wipefs -af "$DRIVE" 2>&1 | tee -a "$LOG_FILE" || fail "Failed to wipe $DRIVE"
    
    # Create GPT partition table
    parted -s "$DRIVE" mklabel gpt 2>&1 | tee -a "$LOG_FILE" || fail "Failed to create partition table"
    
    # Create EFI partition (512MB)
    parted -s "$DRIVE" mkpart ESP fat32 1MiB 513MiB 2>&1 | tee -a "$LOG_FILE"
    parted -s "$DRIVE" set 1 esp on 2>&1 | tee -a "$LOG_FILE"
    
    # Create root partition (rest of disk)
    parted -s "$DRIVE" mkpart primary 513MiB 100% 2>&1 | tee -a "$LOG_FILE"
    
    # Determine partition names (handle nvme vs sd naming)
    if [[ "$DRIVE" == *"nvme"* ]]; then
      BOOT_PART="''${DRIVE}p1"
      ROOT_PART="''${DRIVE}p2"
    else
      BOOT_PART="''${DRIVE}1"
      ROOT_PART="''${DRIVE}2"
    fi
    
    sleep 2  # Wait for partitions to appear
    
    update_progress 20 "formatting" "Formatting partitions..."
    
    # Format EFI partition
    mkfs.fat -F32 -n BOOT "$BOOT_PART" 2>&1 | tee -a "$LOG_FILE" || fail "Failed to format EFI partition"
    
    # Handle encryption if enabled
    if [ "$ENCRYPT" = "true" ] && [ -f "/tmp/easyos-encryption-password" ]; then
      update_progress 25 "encrypting" "Setting up disk encryption..."
      ENCRYPT_PASS=$(cat /tmp/easyos-encryption-password)
      echo -n "$ENCRYPT_PASS" | cryptsetup luksFormat --type luks2 "$ROOT_PART" - 2>&1 | tee -a "$LOG_FILE" || fail "Failed to encrypt partition"
      echo -n "$ENCRYPT_PASS" | cryptsetup open "$ROOT_PART" cryptroot - 2>&1 | tee -a "$LOG_FILE" || fail "Failed to open encrypted partition"
      ROOT_DEV="/dev/mapper/cryptroot"
    else
      ROOT_DEV="$ROOT_PART"
    fi
    
    # Format root as btrfs
    mkfs.btrfs -f -L nixos "$ROOT_DEV" 2>&1 | tee -a "$LOG_FILE" || fail "Failed to format root partition"
    
    update_progress 30 "mounting" "Mounting partitions..."
    
    # Mount root
    mount "$ROOT_DEV" /mnt 2>&1 | tee -a "$LOG_FILE" || fail "Failed to mount root"
    
    # Create btrfs subvolumes
    btrfs subvolume create /mnt/@root 2>&1 | tee -a "$LOG_FILE"
    btrfs subvolume create /mnt/@home 2>&1 | tee -a "$LOG_FILE"
    btrfs subvolume create /mnt/@nix 2>&1 | tee -a "$LOG_FILE"
    btrfs subvolume create /mnt/@log 2>&1 | tee -a "$LOG_FILE"
    
    umount /mnt
    
    # Remount with subvolumes
    mount -o subvol=@root,compress=zstd "$ROOT_DEV" /mnt 2>&1 | tee -a "$LOG_FILE"
    mkdir -p /mnt/{home,nix,var/log,boot}
    mount -o subvol=@home,compress=zstd "$ROOT_DEV" /mnt/home 2>&1 | tee -a "$LOG_FILE"
    mount -o subvol=@nix,compress=zstd "$ROOT_DEV" /mnt/nix 2>&1 | tee -a "$LOG_FILE"
    mount -o subvol=@log,compress=zstd "$ROOT_DEV" /mnt/var/log 2>&1 | tee -a "$LOG_FILE"
    mount "$BOOT_PART" /mnt/boot 2>&1 | tee -a "$LOG_FILE"
    
    update_progress 40 "cloning" "Cloning easeOS configuration..."
    
    # Clone easeOS repo
    mkdir -p /mnt/etc/nixos
    git clone --depth 1 https://github.com/doughty247/easyos.git /mnt/etc/nixos/easyos 2>&1 | tee -a "$LOG_FILE" || fail "Failed to clone easeOS"
    
    update_progress 50 "configuring" "Generating system configuration..."
    
    # Generate hardware config
    nixos-generate-config --root /mnt 2>&1 | tee -a "$LOG_FILE"
    
    # Create easeOS config
    mkdir -p /mnt/etc/easy
    cat > /mnt/etc/easy/config.json << EOF
    {
      "hostName": "$HOSTNAME",
      "timeZone": "UTC",
      "mode": "installed",
      "admin": {
        "username": "$USERNAME"
      }
    }
    EOF
    
    # Create credentials file
    cat > /mnt/etc/easy/credentials.json << EOF
    {
      "username": "$USERNAME",
      "passwordHash": "$PASSWORD_HASH"
    }
    EOF
    chmod 600 /mnt/etc/easy/credentials.json
    
    # Mark as installed
    echo "installed" > /mnt/etc/easy/installed
    
    # WiFi config if provided
    if [ -n "$WIFI_SSID" ]; then
      WIFI_PASS=$(jq -r '.wifiPassword // empty' "$CONFIG_FILE")
      if [ -n "$WIFI_PASS" ]; then
        mkdir -p /mnt/etc/NetworkManager/system-connections
        cat > "/mnt/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection" << EOF
    [connection]
    id=$WIFI_SSID
    type=wifi
    autoconnect=true

    [wifi]
    ssid=$WIFI_SSID
    mode=infrastructure

    [wifi-security]
    key-mgmt=wpa-psk
    psk=$WIFI_PASS

    [ipv4]
    method=auto

    [ipv6]
    method=auto
    EOF
        chmod 600 "/mnt/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection"
      fi
    fi
    
    update_progress 60 "installing" "Installing NixOS (this may take a while)..."
    
    # Run nixos-install
    nixos-install --root /mnt --flake /mnt/etc/nixos/easyos#easyos --no-root-passwd 2>&1 | tee -a "$LOG_FILE" || fail "NixOS installation failed"
    
    update_progress 90 "finalizing" "Finalizing installation..."
    
    # Cleanup
    rm -f /tmp/easyos-password-hash /tmp/easyos-encryption-password /tmp/easyos-install-config.json 2>/dev/null || true
    
    update_progress 100 "complete" "Installation complete! You can now reboot." true
    echo "[INSTALL] Installation complete at $(date)" | tee -a "$LOG_FILE"
  '';

in {
  options.easyos.webui.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable built-in web UI for configuration and installation.";
  };

  config = lib.mkIf cfg.enable {
    # Disable nginx (we use Python server)
    services.nginx.enable = lib.mkForce false;

    # Required packages
    environment.systemPackages = [ pythonWithCrypto pkgs.jq ];

    # Deploy web UI files from source
    environment.etc."easy/webui/server.py" = {
      source = ../webui/server.py;
      mode = "0755";
    };
    
    # Deploy templates
    environment.etc."easy/webui/templates/index.html".source = ../webui/templates/index.html;
    environment.etc."easy/webui/templates/setup.html".source = ../webui/templates/setup.html;
    
    # Deploy static files if they exist
    environment.etc."easy/webui/static" = {
      source = ../webui/static;
      mode = "0755";
    };
    
    # Deploy store apps
    environment.etc."easy/store/apps" = {
      source = storeAppsDir;
      mode = "0755";
    };
    
    # Apply script
    environment.etc."easy/apply.sh" = {
      text = applyScript;
      mode = "0755";
    };
    
    # Web install script (ISO mode)
    environment.etc."easy/webinstall.sh" = {
      text = webinstallScript;
      mode = "0755";
    };

    # Apply service
    systemd.services.easyos-apply = {
      description = "Apply easeOS configuration";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/etc/easy/apply.sh";
      };
    };
    
    # Web install service (ISO mode)
    systemd.services.easyos-webinstall = {
      description = "easeOS Web Installation";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/etc/easy/webinstall.sh";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Web UI service
    systemd.services.easyos-webui = {
      description = "easeOS Web UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pythonWithCrypto}/bin/python3 /etc/easy/webui/server.py";
        Restart = "on-failure";
        RestartSec = "5s";
        StartLimitBurst = 5;
        StartLimitIntervalSec = 60;
        WorkingDirectory = "/etc/easy";
        StateDirectory = "easyos";
      };
    };

    # Firewall
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 1234 ];
  };
}
