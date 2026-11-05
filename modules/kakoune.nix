# Kakoune: editor, language servers and helper tools, all from nix.
#
# This used to build github.com/rileytuttle/kakoune from source for exactly two
# C++ patches: the old `select_line` behaviour on `x`, and a search prompt that
# defaults to the selection instead of the last search term. Both are plain
# config now (see the "line selection" and "search prompt" blocks in
# dotfiles/kakrc), so there is no fork to rebase and no local compile.
#
# The editor comes from inputs.nixpkgs-kakoune rather than the system nixpkgs
# because the kakrc leans on what the editor's rc/ directory ships, and that
# moves: the generic windowing layer the splits are written against only grew a
# niri module after the rev this flake's main nixpkgs is locked to. One small
# input is cheaper than bumping the whole system to chase an editor release.
#
# There are no plugins any more: fzf pickers, sudo saving and the OpenSCAD
# filetype are written directly in dotfiles/kakrc, and per-language smarts come
# from kakoune-lsp. No plug.kak, no `git clone` at editor startup, nothing
# living in ~/.config/kak/plugins.
#
# The package itself lives in pkgs/kakoune.nix so rt-dellpromax-24 (standalone
# home-manager, no NixOS modules) installs the identical build.
{ pkgs, inputs, ... }:

{
  environment.systemPackages = [
    # Brings fzf, ripgrep, file, kak-lsp and the language servers on kak's
    # PATH; see pkgs/kakoune.nix.
    (import ../pkgs/kakoune.nix { inherit pkgs inputs; })
  ];
  environment.variables.EDITOR = "kak";
}
