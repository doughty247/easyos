{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  backupCfg = if (cfgJSON ? backup) then cfgJSON.backup else {};
  enabledFromJSON = if (backupCfg ? enable) then backupCfg.enable else false;
  onCalendar = if (backupCfg ? onCalendar) then backupCfg.onCalendar else "daily";
  targetType = if (backupCfg ? targetType) then backupCfg.targetType else "local"; # local|ssh
  target = if (backupCfg ? target) then backupCfg.target else "/srv/backup"; # dir for local or "user@host:/path" for ssh
  subvols = if (backupCfg ? subvolumes) then backupCfg.subvolumes else [ "/" "/home" "/var" ];
  compress = if (backupCfg ? compress) then backupCfg.compress else false;
  btrfs = pkgs.btrfs-progs;
  ssh = pkgs.openssh;
  coreutils = pkgs.coreutils;
  dashList = lib.concatStringsSep "\n" subvols;
  script = pkgs.writeShellScript "easyos-backup.sh" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ btrfs ssh coreutils pkgs.util-linux pkgs.gnugrep pkgs.findutils pkgs.gawk ]}

    TARGET_TYPE=${lib.escapeShellArg targetType}
    TARGET=${lib.escapeShellArg target}
    SNAPROOT=/var/lib/easyos/backup-snaps
    mkdir -p "$SNAPROOT"

    # sanitize subvolume list
    readarray -t SUBVOLS <<'EOF'
${dashList}
EOF

    timestamp=$(date +%F-%H%M%S)

    cleanup() {
      # Remove any snapshots older than 7 days to prevent buildup
      find "$SNAPROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print0 | xargs -0 -r rm -rf --
    }

    send_local() {
      local snap="$1" base="$(basename "$1")"
      local dest="$TARGET/$base"
      mkdir -p "$TARGET"
      btrfs send "$snap" | btrfs receive "$TARGET"
    }

    send_ssh() {
      local snap="$1" base="$(basename "$1")"
      local host="${target}"
      local remote_dir=${lib.escapeShellArg (if targetType == "ssh" then (builtins.elemAt (lib.splitString ":" target) 1) else "")}
      # target format: user@host:/path
      local remote_path="${target}"
      btrfs send "$snap" | ssh -o BatchMode=yes "$remote_path" "btrfs receive \"${lib.escapeShellArg (if targetType == "ssh" then (builtins.elemAt (lib.splitString ":" target) 1) else "/backup")}\""
    }

    for sv in "${lib.concatStringsSep " " (map (s: lib.escapeShellArg s) subvols)}"; do
      if mount | grep -q "on $sv type btrfs"; then
        name=$(echo "$sv" | tr '/' '_' )-"$timestamp"
        snap="$SNAPROOT/$name"
        echo "Creating read-only snapshot of $sv -> $snap"
        mkdir -p "$snap"
        btrfs subvolume snapshot -r "$sv" "$snap"
        echo "Sending $snap to target ($TARGET_TYPE)"
        if [ "$TARGET_TYPE" = "local" ]; then
          send_local "$snap"
        else
          send_ssh "$snap"
        fi
      else
        echo "WARN: $sv is not a btrfs mount; skipping" >&2
      fi
    done

    cleanup
  '';

in {
  options.easyos.backup.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable JSON-driven automated btrfs backups (service+timer).";
  };

  config = lib.mkIf (config.easyos.backup.enable && enabledFromJSON) {
    environment.systemPackages = [ pkgs.btrfs-progs pkgs.openssh ];

    systemd.services.easyos-backup = {
      description = "EASYOS btrfs backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ script ];
        Nice = 10;
        IOSchedulingClass = "idle";
      };
      # Require target dir for local mode
      unitConfig.ConditionPathIsDirectory = lib.mkIf (targetType == "local") target;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };

    systemd.timers.easyos-backup = {
      description = "EASYOS btrfs backup timer";
      wantedBy = [ "timers.target" ];
      partOf = [ "easyos-backup.service" ];
      timerConfig = {
        OnCalendar = onCalendar; # e.g., "daily" or "03:30"
        Persistent = true;
        AccuracySec = "5min";
        RandomizedDelaySec = "10min";
      };
    };
  };
}
