# GUI applications for personal machines. Kept out of home/core.nix so a
# work or headless host can take the shell environment without dragging in
# spotify and a 3D slicer.
{
  pkgs,
  ...
}:

{
  # The `terminal` command and the choice of emulator behind it. Here rather
  # than in core.nix for the same reason as everything else in this file: a
  # headless host has nothing to open a window with.
  imports = [ ./terminal.nix ];

  home.packages = with pkgs; [
    bitwarden-desktop
    discord
    firefox
    # Nightly, not the 2021.01 release `openscad` points at. 2021.01 renders
    # with CGAL; the nightly defaults to the Manifold backend, which is the
    # whole reason for being here -- on keysmart-clone.scad, F6 goes from
    # 4.9s to 0.12s and the full run 16.3s to 2.6s (BOSL2's parse/evaluate
    # got ~4x quicker too, which is the rest of that wall time). Note this
    # is single-threaded either way: neither build links TBB, so the win is
    # the algorithm, not cores.
    #
    # rt-dellpromax-24 reaches the same package through its own wrapper
    # (nixGL for Ubuntu's GL driver, plus an xdg.desktopEntries block). No
    # wrapper needed on NixOS, and the nightly ships its own .desktop.
    openscad-unstable
    prusa-slicer
    rpi-imager
    signal-desktop
    slack
    spotify
    vlc
    xemu
    xournalpp
  ];
}
