# Opt-in home-manager module (wired in flake.nix, not home/default.nix).
# Used by fw12 (as a NixOS home-manager user) and rt-dellpromax-24 (as a
# standalone home-manager config on Ubuntu) — keep it host-agnostic; it
# must not assume NixOS. Host-specific settings go in local.kdl instead
# (see home/niri-generic-linux.nix for how the Dell supplies its own).
#
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
