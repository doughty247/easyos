{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  apps = if cfgJSON ? apps then cfgJSON.apps else {};
  isEnabled = appId: apps ? ${appId} && apps.${appId} ? enable && apps.${appId}.enable;
in {
  config = lib.mkIf (isEnabled "vaultwarden") {
    services.vaultwarden = {
      enable = true;
      environmentFile = "/etc/easy/secrets/vaultwarden.env";
      config = {
        ROCKET_ADDRESS = "0.0.0.0";
        ROCKET_PORT = 8222;
        SIGNUPS_ALLOWED = true;
      };
    };
    networking.firewall.allowedTCPPorts = [ 8222 ];
    
    # Generate admin token
    systemd.services.easy-vaultwarden-secret = {
      description = "Generate Vaultwarden secrets";
      wantedBy = [ "multi-user.target" ];
      before = [ "vaultwarden.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /etc/easy/secrets
        if [ ! -f /etc/easy/secrets/vaultwarden.env ]; then
          TOKEN=$(${pkgs.openssl}/bin/openssl rand -base64 32)
          echo "ADMIN_TOKEN=$TOKEN" > /etc/easy/secrets/vaultwarden.env
          chmod 600 /etc/easy/secrets/vaultwarden.env
        fi
      '';
    };
  };
}
