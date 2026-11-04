# Kakoune: editor and plugins, both from nix.
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
# Plugins are built in here too. wrapKakoune symlink-joins them into
# share/kak/autoload and points KAKOUNE_RUNTIME at the result, so kakoune loads
# them on its own -- no plug.kak, no `git clone` at editor startup, no
# `:plug-install`, and nothing living in ~/.config/kak/plugins. Their sources
# are flake inputs, so `nix flake update` refreshes them.
{ pkgs, inputs, ... }:

let
  kakounePkgs = inputs.nixpkgs-kakoune.legacyPackages.${pkgs.stdenv.hostPlatform.system};

  # buildKakounePluginFrom2Nix copies the source tree to
  # share/kak/autoload/plugins/<pname>; kakoune's autoload walks it, so it does
  # not matter whether a plugin keeps its .kak files in rc/ or at the top level.
  # The version string is cosmetic (it only names the store path), hence the
  # input's own revision.
  plugin =
    pname: src:
    kakounePkgs.kakouneUtils.buildKakounePluginFrom2Nix {
      inherit pname src;
      version = src.shortRev or "unknown";
      # Keep the autoload directory named after the plugin, not the revision,
      # so bumping an input doesn't churn the path kakoune loads it from.
      path = pname;
    };
in
{
  environment.systemPackages = [
    (kakounePkgs.kakoune.override {
      plugins = [
        # <c-p> fzf-mode, and the fzf-grep behind <c-F> and grep-mode G.
        (plugin "fzf-kak" inputs.fzf-kak)

        # openscad filetype. Worth keeping: there are a few hundred .scad files
        # under ~/assorted_3d_model_projects.
        (plugin "openscad-kak" inputs.openscad-kak)

        # Backs the W / Wq aliases defined in the kakrc.
        (plugin "kakoune-sudo-write" inputs.kakoune-sudo-write)
      ];
    })

    # kakoune's rc/detection/file.kak shells out to `file --mime-type` to pick
    # a filetype for anything its extension rules don't cover. Without the
    # binary that silently fails on every buffer open -- "sh: file: command not
    # found" in the *debug* buffer -- and extensionless files get no filetype,
    # so no highlighting and no comment_line. Not pulled in by the kakoune
    # derivation, so name it here.
    pkgs.file
  ];
  environment.variables.EDITOR = "kak";
}
