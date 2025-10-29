# Placeholder hardware configuration
# This file will be replaced during installation with the actual hardware config
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  # Placeholder - will be overwritten during installation
  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # This file gets replaced during nixos-install
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
