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

    kakoune
    # rc/detection/file.kak shells out to `file --mime-type`; see the note in
    # modules/kakoune.nix.
    file
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

  home.sessionVariables = {
  };

  home.stateVersion = "26.11";
  programs.home-manager.enable = true;
}
