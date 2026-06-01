{ config, pkgs, ... }:

{
  imports = [ ./desktop-hardware-configuration.nix ];

  networking.hostname = "beefy";

  # Wired networking is fine with just NetworkManager
  # If you want to use systemd-networkd instead:
  # networking.useNetworkd = true;

  # GPU — pick one:

  # For AMD (recommended, open source):
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;  # for 32-bit games/apps via Steam
  };

  # For Nvidia (if needed):
  # services.xserver.videoDrivers = [ "nvidia" ];
  # hardware.nvidia.modesetting.enable = true;

  # Gaming
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };

  # Desktop-only packages
  environment.systemPackages = with pkgs; [
    discord
    obs-studio
  ];
}
