{ pkgs, inputs, ... }:
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
    glow
    openscad

    # Brings fzf, ripgrep, file, kak-lsp and the language servers on kak's
    # PATH; see pkgs/kakoune.nix.
    kakoune
  ];

  # Same kakrc as home/core.nix. Its splits use termcmd = `terminal`, which
  # home/niri.nix provides here via home/terminal.nix.
  home.file.".config/kak/kakrc".source = ../dotfiles/kakrc;

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
