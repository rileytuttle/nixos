{ config, pkgs, inputs, ... }:

{
  # Pull in the hardware scan NixOS generated at install time
  imports = [
    ./elitedesk-hardware-configuration.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
    ../modules/mergerfs.nix
    ../modules/jellyfin-server.nix
  ];

  networking.hostName = "elitedesk";  # whatever you want

  nixpkgs.config.permittedInsecurePackages = [
    "electron-39.8.10"
    "intel-media-sdk-23.2.2"
  ];

}
