# Bambu Studio on rt-dellpromax-24 (Ubuntu + standalone home-manager).
#
# Two things nixpkgs' package cannot do for itself on a foreign distro:
#
#   1. GL. Same story as OpenSCAD and DMS -- the binary links nix's libEGL
#      and cannot find Ubuntu's driver, so it goes through nixGLIntel. This
#      machine is hybrid (nvidia on card1, i915 on card2) but the display
#      connectors all hang off i915, so Intel is the right wrapper.
#      Consequently the package's `withNvidiaGLWorkaround` (mesa + zink, for
#      people running the plater on proprietary nvidia GL) is left off.
#
#   2. Wayland. nixpkgs builds this against Bambu's wxWidgets 3.1.7 fork, and
#      wxGLCanvas only learned Wayland/EGL in wx 3.2 -- on a native Wayland
#      GDK backend the 3D plater comes up blank. niri is Wayland, so the
#      wrapper defaults GDK_BACKEND to x11 (XWayland). It is a default, not a
#      pin: `GDK_BACKEND=wayland bambu-studio` to re-test after a wx bump.
#
#      That means niri has to have an XWayland to hand. fw12 gets one from
#      modules/niri.nix; this host did not until now, so the matching
#      xwayland-satellite went into home/niri-generic-linux.nix alongside
#      this module. Under Ubuntu's GNOME session the question does not come
#      up -- mutter always has XWayland.
#
# Wrapped via symlinkJoin rather than a bare writeShellScriptBin (the pattern
# the OpenSCAD wrappers in hosts/rt-dellpromax-24.nix use) because unlike
# OpenSCAD this package ships things worth keeping: its .desktop file, the
# hicolor icons, and the MIME associations for 3mf/stl/step plus the
# `bambustudio://` scheme MakerWorld's "open in Bambu Studio" button uses.
# Joining keeps all of that and swaps out only bin/bambu-studio.
#
# Note the package is marked unfree (the proprietary networking plugin it
# downloads on first launch is an unresolved AGPL violation, see
# nixpkgs#415821), so Hydra does not build it: expect a local compile of
# wxWidgets + BambuStudio on the first switch after a nixpkgs bump.
# allowUnfree is already set for this host's pkgs in flake.nix.
#
# That downloaded plugin -- ~/.config/BambuStudio/plugins/libbambu_networking.so
# -- is what cloud and LAN printer connections go through. It is a stock glibc
# shared object dlopened from a nix-built process, so if device discovery or
# login misbehaves, that is the thing to suspect; slicing and exporting to SD
# do not need it.
{ pkgs, ... }:
let
  nixGLBin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";

  unwrapped = pkgs.bambu-studio;

  wrapper = pkgs.writeShellScript "bambu-studio" ''
    # Prefer XWayland, but only when there is an X display to prefer: with
    # DISPLAY unset, pinning GDK_BACKEND=x11 turns "the 3D view is blank"
    # into "the app does not start", which is a worse failure to debug.
    if [ -z "''${GDK_BACKEND:-}" ] && [ -n "''${DISPLAY:-}" ]; then
      export GDK_BACKEND=x11
    fi
    exec ${nixGLBin} ${unwrapped}/bin/bambu-studio "$@"
  '';

  bambu-studio = pkgs.symlinkJoin {
    name = "bambu-studio-nixgl-${unwrapped.version}";
    paths = [ unwrapped ];
    inherit (unwrapped) meta;
    postBuild = ''
      rm $out/bin/bambu-studio
      ln -s ${wrapper} $out/bin/bambu-studio

      # Upstream ships `Exec=bambu-studio %U`, i.e. resolved off the launcher's
      # PATH. That would land on the wrapper anyway (it is the only
      # bambu-studio in the profile), but point it at the store path so a
      # launcher started with a thin PATH still gets the nixGL route.
      for desktop in $out/share/applications/*.desktop; do
        [ -e "$desktop" ] || continue
        target=$(readlink -f "$desktop")
        rm "$desktop"
        sed 's|^Exec=.*bambu-studio|Exec='"$out"/bin/bambu-studio'|' \
          "$target" > "$desktop"
      done
    '';
  };
in
{
  home.packages = [ bambu-studio ];
}
