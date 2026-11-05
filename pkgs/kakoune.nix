# Kakoune plus every program the kakrc shells out to, as a plain package so
# both kinds of host can install it: the NixOS hosts through
# environment.systemPackages (modules/kakoune.nix), rt-dellpromax-24 --
# standalone home-manager on Ubuntu -- through home.packages. See
# modules/kakoune.nix for why the editor comes from inputs.nixpkgs-kakoune.
#
# No plugins: fzf pickers, sudo saving and the OpenSCAD filetype are all
# written directly in dotfiles/kakrc, and language smarts come from
# kakoune-lsp below.
{ pkgs, inputs }:

let
  kakounePkgs = inputs.nixpkgs-kakoune.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  kakoune = kakounePkgs.kakoune;

  # Put on kak's PATH rather than installed per host, because rt-dellpromax-24
  # doesn't take home/core.nix and so had none of them -- the fzf pickers
  # failed there with nothing on screen to say why.
  runtimeDeps = with kakounePkgs; [
    # Used by the kakrc directly
    fzf # the <c-p> pickers and fzf grep
    ripgrep # grepcmd, and the fzf grep picker
    file # rc/detection/file.kak runs `file --mime-type` to pick a filetype
    #      for anything its extension rules don't cover; without it every
    #      buffer open logs "sh: file: command not found" to *debug*

    # LSP client, and one server per filetype the kakrc enables it for (see
    # the "lsp" section there for which filetype gets which)
    kakoune-lsp
    clang-tools # clangd (also clang-format, clang-tidy)
    basedpyright
    ruff
    bash-language-server
    shellcheck # bash-language-server runs it for diagnostics
    shfmt # bash-language-server runs it for formatting
    vscode-langservers-extracted # vscode-json-language-server
    yaml-language-server
    docker-language-server # compose files; BuildKit checks on Dockerfiles
    dockerfile-language-server # Dockerfile instruction docs, completion, lint
    lemminx # XML
    nixd
    openscad-lsp
  ];
in
# --suffix, so a host's own copies still win -- e.g. a work project's own
# clangd. The rt-fzf runner in the kakrc copies kak's PATH into the script it
# hands to tmux, so these are found there too even though tmux panes start
# from the tmux server's environment.
pkgs.symlinkJoin {
  name = "kakoune-${kakounePkgs.kakoune-unwrapped.version}";
  paths = [ kakoune ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/kak --suffix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
  '';
}
