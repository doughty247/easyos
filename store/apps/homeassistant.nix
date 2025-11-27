{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  apps = if cfgJSON ? apps then cfgJSON.apps else {};
  isEnabled = appId: apps ? ${appId} && apps.${appId} ? enable && apps.${appId}.enable;
in {
  config = lib.mkIf (isEnabled "homeassistant") {
    services.home-assistant = {
      enable = true;
      openFirewall = true;
      extraComponents = [
        "esphome"
        "met"
        "radio_browser"
        "cast"
        "dlna_dmr"
        "upnp"
      ];
      config = {
        homeassistant = {
          name = "Home";
          unit_system = "metric";
        };
        default_config = {};
        http = {
          server_host = [ "0.0.0.0" ];
          use_x_forwarded_for = true;
          trusted_proxies = [ "127.0.0.1" "::1" ];
        };
      };
    };
  };
}
