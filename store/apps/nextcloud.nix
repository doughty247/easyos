{ lib, config, pkgs, ... }:
let
  jsonPath = "/etc/easy/config.json";
  jsonExists = builtins.pathExists jsonPath;
  cfgJSON = if jsonExists then builtins.fromJSON (builtins.readFile jsonPath) else {};
  apps = if cfgJSON ? apps then cfgJSON.apps else {};
  isEnabled = appId: apps ? ${appId} && apps.${appId} ? enable && apps.${appId}.enable;
  
  getAppConfig = appId: defaults: 
    let appConf = apps.${appId} or {};
    in defaults // (lib.filterAttrs (n: v: n != "enable") appConf);

  appCfg = getAppConfig "nextcloud" {
    hostName = "${config.networking.hostName}.local";
    https = false;
  };
in {
  config = lib.mkIf (isEnabled "nextcloud") {
    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud29;
      hostName = appCfg.hostName;
      config.adminpassFile = "/etc/easy/secrets/nextcloud-admin";
      https = appCfg.https;
      
      # Use PostgreSQL for better performance/reliability
      configureRedis = true;
      database.createLocally = true;
      config.dbtype = "pgsql";
      
      # Allow access from any IP (essential for local appliance usage)
      settings.trusted_domains = [ "*" ];
    };
    networking.firewall.allowedTCPPorts = [ 80 443 ];

    # Generate admin password if missing
    systemd.services.easy-nextcloud-secret = {
      description = "Generate Nextcloud admin secret";
      wantedBy = [ "multi-user.target" ];
      before = [ "nextcloud-setup.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /etc/easy/secrets
        if [ ! -f /etc/easy/secrets/nextcloud-admin ]; then
          ${pkgs.coreutils}/bin/tr -dc A-Za-z0-9 < /dev/urandom | ${pkgs.coreutils}/bin/head -c 16 > /etc/easy/secrets/nextcloud-admin
          ${pkgs.coreutils}/bin/chmod 600 /etc/easy/secrets/nextcloud-admin
        fi
      '';
    };
  };
}
