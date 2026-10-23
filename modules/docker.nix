{ config, pkgs, ... }:

{
  virtualisation.docker.enable = true;

  # Docker's post-install step: membership in the docker group lets the
  # user talk to the daemon socket without sudo. Note this is effectively
  # root access. Takes effect after logging out and back in.
  users.users.rileytuttle.extraGroups = [ "docker" ];

  environment.systemPackages = [ pkgs.docker-compose ];
}
