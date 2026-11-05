# Kakoune with my plugins built in, as a plain package so both kinds of host
# can install it: the NixOS hosts through environment.systemPackages
# (modules/kakoune.nix), rt-dellpromax-24 -- standalone home-manager on
# Ubuntu -- through home.packages. See modules/kakoune.nix for why the editor
# comes from inputs.nixpkgs-kakoune and why plugins are inputs, not plug.kak.
{ pkgs, inputs }:

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
kakounePkgs.kakoune.override {
  plugins = [
    # <c-p> fzf-mode, and the fzf-grep behind <c-F> and grep-mode G.
    (plugin "fzf-kak" inputs.fzf-kak)

    # openscad filetype. Worth keeping: there are a few hundred .scad files
    # under ~/assorted_3d_model_projects.
    (plugin "openscad-kak" inputs.openscad-kak)

    # Backs the W / Wq aliases defined in the kakrc.
    (plugin "kakoune-sudo-write" inputs.kakoune-sudo-write)
  ];
}
