# modules/listenarr.nix
{ config, pkgs, lib, ... }:

{
  # Listenarr has no nixpkgs package or NixOS module (checked against
  # nixos-unstable), and upstream only ships container images, so this runs
  # the official image as a systemd unit via oci-containers.
  #
  # "canary" is upstream's rolling pre-release tag, built from every push to
  # the canary branch -- it moves without warning and is explicitly beta
  # software. pull = "newer" means `systemctl restart docker-listenarr`
  # picks up whatever canary points at today.
  virtualisation.oci-containers = {
    backend = "docker";

    containers.listenarr = {
      image = "ghcr.io/listenarrs/listenarr:canary";
      pull = "newer";
      autoStart = true;

      ports = [ "0.0.0.0:4545:4545" ];

      environment = {
        # Own downloaded files as rileytuttle:users, same as transmission
        # and nzbget do, so all three stacks can read each other's output.
        # Confirm the uid with `id -u rileytuttle` -- it is only 1000 because
        # rileytuttle is the first normal user; gid 100 is NixOS's "users".
        PUID = "1000";
        PGID = "100";
        UMASK = "002";
        LISTENARR_LOG_LEVEL = "Information";
        # Only needed if you wire up the Discord bot:
        # LISTENARR_PUBLIC_URL = "https://listenarr.example.com";
      };

      volumes = [
        "/var/lib/listenarr:/app/config"
        "/home/rileytuttle/audiobooks:/audiobooks"
        # Listenarr imports from the download clients' *completed* dirs, so
        # mount those rather than the whole tree -- both then look flat on
        # this side, and nzbget's queue/tmp/intermediate stay out of the
        # container. Remote path mappings to set in the Listenarr UI:
        #   transmission  /home/rileytuttle/transmission      -> /downloads/transmission
        #   nzbget        /home/rileytuttle/nzbget/completed  -> /downloads/nzbget
        # Read-write so it can move finished books into /audiobooks.
        "/home/rileytuttle/transmission:/downloads/transmission"
        "/home/rileytuttle/nzbget/completed:/downloads/nzbget"
      ];

      extraOptions = [
        # Reach transmission (9091) and nzbget (6789) on the host as
        # host.docker.internal instead of hardcoding a LAN IP. Docker does not
        # provide this name on linux by default, hence the explicit alias.
        # On the podman backend the equivalent is host.containers.internal,
        # which podman already defines for you.
        "--add-host=host.docker.internal:host-gateway"
      ];
    };
  };

  # A rolling tag plus pull = "newer" leaves a dangling image behind on every
  # update, so sweep them up weekly. Default flags prune stopped containers,
  # unused networks, dangling images and build cache -- not tagged images.
  virtualisation.docker.autoPrune.enable = true;

  # The docker backend adds a "docker" group, and membership in it is
  # root-equivalent (you can bind-mount / into a privileged container).
  # Uncomment only if you want to run the docker CLI without sudo.
  # users.users.rileytuttle.extraGroups = [ "docker" ];

  # Neither backend creates a missing bind-mount source sensibly -- it gets
  # made as a root-owned directory, which would then break transmission or
  # nzbget writing into it. tmpfiles runs at sysinit, before any of the three
  # services, so these always exist first with the right owner.
  systemd.tmpfiles.rules = [
    "d /var/lib/listenarr 0750 rileytuttle users -"
    "d /home/rileytuttle/audiobooks 0775 rileytuttle users -"
    "d /home/rileytuttle/transmission 0775 rileytuttle users -"
    "d /home/rileytuttle/nzbget/completed 0775 rileytuttle users -"
  ];

  # Belt and braces only: published container ports are DNAT'd straight into
  # the container and never traverse the INPUT chain the NixOS firewall
  # filters, so this line does not actually gate access on either backend. To
  # really restrict it, change ports above to "127.0.0.1:4545:4545" (or the
  # tailscale IP) instead of 0.0.0.0.
  networking.firewall.allowedTCPPorts = [ 4545 ];
}
