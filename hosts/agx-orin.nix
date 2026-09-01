{ pkgs, ... }:
{
  home.username = "rileytuttle";
  home.homeDirectory = "/home/rileytuttle";
  home.packages = with pkgs; [
    chromium
  ];

  home.sessionVariables = {
  };

  home.stateVersion = "26.11";
  programs.home-manager.enable = true;
}
