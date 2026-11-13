# OpenSCAD 2021.01 release as `openscad-stable`, alongside the nightly
# `openscad` in hosts/rt-dellpromax-24.nix. Not imported anywhere: add it to
# a host's modules list in flake.nix if it's needed full-time, otherwise
# just run it ad hoc:
#
#   nix run --impure github:nix-community/nixGL#nixGLIntel -- \
#     $(nix build --no-link --print-out-paths nixpkgs#openscad)/bin/openscad
#
# The nixGL part is only needed for the GUI; for CLI use (e.g. STL export)
# plain `nix run nixpkgs#openscad -- ...` is enough. --impure is required
# by nixGL's flake.
#
# Wrapped rather than installed directly because openscad and
# openscad-unstable both ship bin/openscad and would collide. Assumes the
# host's pkgs carries the nixgl overlay (see flake.nix) — OpenSCAD's
# Qt/OpenGL preview can't see Ubuntu's GL driver unwrapped.
{ pkgs, ... }:
let
  nixGLBin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";
  openscad-stable = pkgs.writeShellScriptBin "openscad-stable" ''
    exec ${nixGLBin} ${pkgs.openscad}/bin/openscad "$@"
  '';
in
{
  home.packages = [ openscad-stable ];

  xdg.desktopEntries.openscad-stable = {
    name = "OpenSCAD (stable)";
    genericName = "3D CAD Modeller";
    exec = "openscad-stable %f";
    icon = "openscad";
    categories = [
      "Graphics"
      "3DGraphics"
      "Engineering"
    ];
    mimeType = [ "application/x-openscad" ];
  };
}
