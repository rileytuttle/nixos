{ config, pkgs, ... }:

{
  services.jellyfin = {
    enable = true;
    # Set false if this box only needs to be reachable over tailnet --
    # in that case skip this and hit it at http://<tailscale-ip>:8096
    openFirewall = false;
  };

  environment.systemPackages = with pkgs; [
    jellyfin-ffmpeg
  ];

  # Give jellyfin read/write access to the mergerfs pool.
  # Assumes the "media" group from mergerfs.nix owns /mnt/storage/media.
  # users.users.jellyfin.extraGroups = [ "media" ];

  ##########################################################################
  # Hardware transcoding (uncomment + adjust for your GPU)
  ##########################################################################

  # -- Intel iGPU / VA-API --
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      libva-vdpau-driver
      intel-media-sdk
    ];
  };
  users.users.jellyfin.extraGroups = [ "media" "video" "render" ];

  # -- NVIDIA (NVENC/NVDEC) --
  # hardware.nvidia.modesetting.enable = true;
  # hardware.graphics.enable = true;
  # users.users.jellyfin.extraGroups = [ "media" "video" "render" ];

}
