{ config, pkgs, inputs, ... }:

{
  # Pull in the hardware scan NixOS generated at install time
  imports = [
    ./elitedesk-hardware-configuration.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
    ../modules/mergerfs.nix
    ../modules/jellyfin-server.nix
    ../modules/remote-backup.nix
  ];

  networking.hostName = "elitedesk";  # whatever you want

  services.remoteBackup = {
    enable = true;
    remoteHost = "mahi";
    remoteUser = "root";
    sshKeyFile = "/root/.ssh/id_unraid_backup";

    # Optional: point notifications wherever you like (ntfy, webhook, mail...)
    # notifyScript = pkgs.writeShellScript "notify" ''
    #   ${pkgs.curl}/bin/curl -s -H "Title: $1" -d "$2" https://ntfy.sh/your-topic-here
    # '';

    jobs = {
      # Deterministic placement: bypass the mergerfs pool, write straight
      # to one physical branch.
      tuttle_family_documents = {
        source      = "/mnt/user/TuttleFamily";
        destination = "/mnt/storage/backup/TuttleFamily";
      };

      courtney_riley_photos = {
        source      = "/mnt/user/CourtneyRileyPhotos";
        destination = "/mnt/storage/backup/CourtneyRileyPhotos";
      };

      books = {
        source      = "/mnt/user/starr_media/media/books";
        destination = "/mnt/storage/starr_media/media/books";
      };
      library = {
        source      = "/mnt/user/library";
        destination = "/mnt/storage/library";
      };
   };
  };

  nixpkgs.config.permittedInsecurePackages = [
    "electron-39.8.10"
    "intel-media-sdk-23.2.2"
  ];

}
