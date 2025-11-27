{ lib, config, pkgs, ... }:
{
  imports = [
    ../store/apps/immich.nix
    ../store/apps/nextcloud.nix
    ../store/apps/jellyfin.nix
    ../store/apps/homeassistant.nix
    ../store/apps/vaultwarden.nix
  ];
}
