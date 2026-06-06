{ pkgs, config, inputs, ... }:
let niri = inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri;
in
{

  environment.systemPackages = with pkgs; [
    niri
    gnome-terminal
    wl-clipboard
    fuzzel
    swaylock
  ];

  # home.file.".config/niri/config.kdl".source = "${inputs.dotfiles}/dotfiles/niri/config.kdl";
  # home.file.".config/ashell".source = "${inputs.dotfiles}/dotfiles/ashell";
}
