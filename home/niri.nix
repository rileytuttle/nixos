{ pkgs, config, inputs, ... }:
{

  imports = [ inputs.nix-colors.homeManagerModules.default ];
  colorScheme = inputs.nix-colors.colorSchemes.dracula;

  programs.niri = {
    enable = true;
  };

  home.packages = with pkgs; [
    gnome-terminal
    wl-clipboard
    fuzzel
    swaylock
  ];

  home.file.".config/niri/config.kdl".source = "${inputs.dotfiles}/dotfiles/niri/config.kdl";
  # home.file.".config/ashell".source = "${inputs.dotfiles}/dotfiles/ashell";
}
