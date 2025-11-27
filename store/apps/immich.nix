{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  apps = if cfgJSON ? apps then cfgJSON.apps else {};
  isEnabled = appId: apps ? ${appId} && apps.${appId} ? enable && apps.${appId}.enable;
in {
  config = lib.mkIf (isEnabled "immich") {
    services.immich = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
      mediaLocation = "/var/lib/immich";
    };
  };
}
