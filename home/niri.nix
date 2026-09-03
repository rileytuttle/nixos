# fw12-only home-manager module (wired in flake.nix, not home/default.nix).
# Delivers niri-config.kdl (this repo's copy, based on niri's stock default
# config plus the DMS spawn/keybinds below). Kept as its own file, separate
# from home/default.nix, so it's a single import to delete if niri doesn't
# work out. Once you've settled on tweaks, move niri-config.kdl over to
# your dotfiles repo and point this at `${inputs.dotfiles}/...` instead.
#
# config.kdl `include`s an unmanaged ~/.config/niri/local.kdl (not declared
# here on purpose) for scratch tweaks that shouldn't need a rebuild.
{ pkgs, ... }:

{
  home.packages = with pkgs; [ wvkbd ];
  xdg.configFile."niri/config.kdl".source = ./niri-config.kdl;
}
