{ pkgs, ... }:
let
  # Same mesa wrapper DMS runs under (see home/niri-generic-linux.nix):
  # OpenSCAD's Qt/OpenGL preview links nix's libEGL and can't see Ubuntu's
  # GL driver unwrapped.
  nixGLBin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";

  # Nightly, under the plain `openscad` name. The 2021.01 release lives in
  # home/openscad-stable.nix, which isn't wired in.
  openscad = pkgs.writeShellScriptBin "openscad" ''
    exec ${nixGLBin} ${pkgs.openscad-unstable}/bin/openscad "$@"
  '';
in
{
  home.username = "rileytuttle";
  home.homeDirectory = "/home/rileytuttle";
  home.packages = with pkgs; [
    chromium
    glow
    openscad
  ];

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
