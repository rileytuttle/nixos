{ lib, pkgs, inputs, ... }:
let
  # Same mesa wrapper DMS runs under (see home/niri-generic-linux.nix):
  # OpenSCAD's Qt/OpenGL preview links nix's libEGL and can't see Ubuntu's
  # GL driver unwrapped.
  nixGLBin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";

  # Nightly, under the plain `openscad` name.
  openscad = pkgs.writeShellScriptBin "openscad" ''
    exec ${nixGLBin} ${pkgs.openscad-unstable}/bin/openscad "$@"
  '';

  # Same kakoune + plugins the NixOS hosts get from modules/kakoune.nix.
  kakoune = import ../pkgs/kakoune.nix { inherit pkgs inputs; };
in
{
  home.username = "rileytuttle";
  home.homeDirectory = "/home/rileytuttle";
  home.packages = with pkgs; [
    chromium
    openscad

    # Brings fzf, ripgrep, file, kak-lsp and the language servers on kak's
    # PATH; see pkgs/kakoune.nix.
    kakoune
  ];

  # kakrc and .tmux.conf come from home/core.nix, as does kak's `glow` -- all
  # three used to be spelled out here because this host did not import that
  # file yet. (kakrc's splits use termcmd = `terminal`, which home/niri.nix
  # provides here via home/terminal.nix.) Note core.nix also puts nix's tmux
  # on PATH ahead of Ubuntu's: after the first switch, `tmux kill-server`
  # once so a new client is not left talking to the old apt server.

  # Standalone home-manager, so core.nix's NixOS `rebuild` alias (which shells
  # out to nixos-rebuild) is wrong here. It is mkDefault there; this wins.
  programs.bash.shellAliases.rebuild =
    "home-manager switch --flake $HOME/nixos#rt-dellpromax-24";

  # home-manager owns ~/.bashrc from here on, which drops the handful of
  # things Ubuntu's stock one provided. These are the ones worth keeping;
  # everything else in it was interactive-shell boilerplate home-manager
  # already covers.
  programs.bash.initExtra = lib.mkAfter ''
    if [ -x /usr/bin/dircolors ]; then
      eval "$(dircolors -b)"
      alias ls='ls --color=auto'
      alias grep='grep --color=auto'
    fi
    alias ll='ls -alF'
    alias la='ls -A'
  '';

  # The wrapper carries no .desktop file, so give fuzzel something to find.
  xdg.desktopEntries.openscad = {
    name = "OpenSCAD";
    genericName = "3D CAD Modeller (nightly)";
    exec = "openscad %f";
    icon = "openscad";
    categories = [ "Graphics" "3DGraphics" "Engineering" ];
    mimeType = [ "application/x-openscad" ];
  };

  # Claude Code in a container, from home/claude-container.nix. The one thing
  # it needs that nix cannot supply is the container runtime itself -- a daemon
  # socket or a setuid newuidmap, which has to be Ubuntu's own. So `apt install
  # podman` (preferred: rootless, and then the container owns its /nix *and*
  # writes workspace files as this user), or use the docker that is already
  # here for balena work. runtime is left null so it picks up whichever is on
  # PATH.
  programs.claude-container = {
    enable = true;
    aliases = [ "claude-c" "claude" ];
  };

  home.sessionVariables = {
  };

  home.stateVersion = "26.11";
  programs.home-manager.enable = true;
}
