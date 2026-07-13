# modules/steam.nix
{ config, pkgs, lib, ... }:

{
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;          # Steam Remote Play
    dedicatedServer.openFirewall = true;       # Source dedicated servers (LAN hosting)
    localNetworkGameTransfers.openFirewall = true; # Steam Local Network Game Transfers
    gamescopeSession.enable = true;            # Gamescope as a session/compositor option
  };

  # Enable GameMode for performance optimizations
  programs.gamemode.enable = true;

  # 32-bit graphics/audio support (needed for many older games)
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Allow unfree packages required by Steam
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "steam"
      "steam-original"
      "steam-unwrapped"
      "steam-run"
    ];

  environment.systemPackages = with pkgs; [
    protonup-qt  # easy install of GE-Proton etc.
  ];
}
