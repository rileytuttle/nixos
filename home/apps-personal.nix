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
    openscad
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
