# modules/transmission.nix
{ config, pkgs, lib, ... }:

{
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    openRPCPort = true;

    # flood-for-transmission replaces the built-in web UI
    # webHome = pkgs.flood-for-transmission;

    settings = {
      rpc-bind-address = "0.0.0.0";
      rpc-whitelist-enabled = false;
      rpc-authentication-required = true;
      rpc-username = "rileytuttle";
      rpc-password = "rileytuttle";
      rpc-port = 9091;

      download-dir = "/home/rileytuttle/transmission/";
      incomplete-dir = "/home/rileytuttle/transmission/.incomplete";
      incomplete-dir-enabled = true;

      peer-port = 51413;
      utp-enabled = true;
    };
    downloadDirPermissions = "0775";
  };

  # let your user actually access files the daemon owns
  users.users.rileytuttle.extraGroups = [ "transmission" ];

  # open peer port in addition to the RPC port
  networking.firewall.allowedTCPPorts = [ 51413 ];
  networking.firewall.allowedUDPPorts = [ 51413 ];
}
