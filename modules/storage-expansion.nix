{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};

  storage = if (cfgJSON ? storage) then cfgJSON.storage else {};
  auto = if (storage ? auto) then storage.auto else false;
  devices = if (storage ? devices) then storage.devices else [];
  mountPoint = if (storage ? mountPoint) then storage.mountPoint else "/";
  profile = if (storage ? profile) then storage.profile else "raid1"; # raid1|single|raid5|raid6 etc.
  guardFile = "/var/lib/easyos/.storage-expand-done";

  btrfs = pkgs.btrfs-progs;
  grep = pkgs.gnugrep;
  core = pkgs.coreutils;
  script = pkgs.writeShellScript "easyos-storage-expand.sh" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ btrfs grep core pkgs.util-linux ]}

    MNT=${lib.escapeShellArg mountPoint}
    PROFILE=${lib.escapeShellArg profile}
    GUARD=${lib.escapeShellArg guardFile}
    mkdir -p "$(dirname "$GUARD")"

    if [ -f "$GUARD" ]; then
      echo "Storage expansion already completed; exiting."
      exit 0
    fi

    echo "Checking btrfs filesystem at $MNT"
    if ! btrfs filesystem show "$MNT" >/dev/null 2>&1; then
      echo "ERROR: $MNT is not a btrfs filesystem or not mounted" >&2
      exit 1
    fi

    # Add missing devices
    for dev in ${lib.concatStringsSep " " (map (d: lib.escapeShellArg d) devices)}; do
      if btrfs filesystem show "$MNT" | grep -q " path $dev\>"; then
        echo "Device $dev already part of the filesystem"
      else
        echo "Adding device $dev to $MNT"
        btrfs device add -f "$dev" "$MNT"
      fi
    done

    # Convert to desired profile and balance data+metadata
    echo "Starting balance/convert to $PROFILE"
    btrfs balance start -dconvert=$PROFILE -mconvert=$PROFILE -f "$MNT"

    # Mark done to avoid repeated runs
    touch "$GUARD"
  '';

in {
  options.easyos.storage.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable JSON-driven storage expansion (btrfs device add + balance).";
  };

  config = lib.mkIf (config.easyos.storage.enable && auto && (devices != [])) {
    environment.systemPackages = [ pkgs.btrfs-progs ];

  systemd.services.easyos-storage-expand = {
      description = "EASYOS btrfs storage expansion";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ script ];
      };
      unitConfig = {
        ConditionPathExists = [ mountPoint "!${guardFile}" ];
      };
    };
  };
}
