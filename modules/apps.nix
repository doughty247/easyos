{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  
  apps = if cfgJSON ? apps then cfgJSON.apps else {};
  immichEnabled = apps ? immich && apps.immich ? enable && apps.immich.enable;
in {
  config = lib.mkIf immichEnabled {
    services.immich = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };
  };
}
