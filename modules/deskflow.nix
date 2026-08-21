# system config module (e.g. modules/deskflow.nix), imported per-host
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.deskflow ];

  # if you're running the server on this box and want it reachable on LAN
  networking.firewall.allowedTCPPorts = [ 24800 ];
}
