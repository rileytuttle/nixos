# modules/nzbget.nix
{ config, pkgs, lib, ... }:

{
  services.nzbget = {
    enable = true;

    user = "rileytuttle";
    group = "users";

    # Passed to nzbget as `-o Name=value` overrides on top of the config it
    # drops in /var/lib/nzbget/nzbget.conf on first boot. Anything you change
    # in the web UI that is also set here gets overwritten on the next
    # restart -- so treat this list as the source of truth, not the UI.
    # Option reference:
    #   https://github.com/nzbgetcom/nzbget/blob/develop/nzbget.conf
    settings = {
      ControlIP = "0.0.0.0";
      ControlPort = 6789;
      ControlUsername = "rileytuttle";
      ControlPassword = "rileytuttle";

      MainDir = "/home/rileytuttle/nzbget";
      DestDir = "/home/rileytuttle/nzbget/completed";
      InterDir = "/home/rileytuttle/nzbget/intermediate";
      NzbDir = "/home/rileytuttle/nzbget/nzb";
      QueueDir = "/home/rileytuttle/nzbget/queue";
      TempDir = "/home/rileytuttle/nzbget/tmp";
      ScriptDir = "/home/rileytuttle/nzbget/scripts";

      # Unpack in place as articles land instead of after the whole download
      Unpack = true;
      DirectUnpack = true;
      ParCheck = "auto";
      ParRepair = true;

      # Pause the queue when the download disk gets this low (MB)
      DiskSpace = 5000;

      # Roughly "how much RAM may nzbget use to avoid thrashing the disk"
      ArticleCache = 700;
      WriteBuffer = 1024;

      # Usenet provider. nzbget cannot download anything without at least one
      # server, so fill this in and uncomment. Server1.Password would land
      # world-readable in the nix store and in `ps` output -- if that matters,
      # leave these commented and add the server once through the web UI.
      # "Server1.Active" = true;
      # "Server1.Name" = "main";
      # "Server1.Host" = "news.example.com";
      # "Server1.Port" = 563;
      # "Server1.Username" = "REPLACE-ME";
      # "Server1.Password" = "REPLACE-ME";
      # "Server1.Encryption" = true;
      # "Server1.Connections" = 20;
      # "Server1.Level" = 0;
    };
  };

  # services.nzbget has no openFirewall option (it was removed upstream), so
  # the control port has to be opened by hand.
  networking.firewall.allowedTCPPorts = [ 6789 ];
}
