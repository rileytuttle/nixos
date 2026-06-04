{ config, pkgs, lib, inputs, ... }:
{
  
  programs.hyprland = {
    enable = true;
    # set the flake package
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };

  environment.systemPackages = with pkgs; [
    kdePackages.dolphin
    kitty
    gnome-terminal
    mako
    wl-clipboard
    hyprpolkitagent
    alsa-utils
    hyprpaper
    hyprpwcenter
    hyprsunset
    hypridle
    hyprlock
    hyprsysteminfo
    hyprgraphics
    brightnessctl
    playerctl
    inputs.ashell.packages.${pkgs.system}.default
    hyprlauncher
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
  ];

}
