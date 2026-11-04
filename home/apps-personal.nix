# GUI applications for personal machines. Kept out of home/core.nix so a
# work or headless host can take the shell environment without dragging in
# spotify and a 3D slicer.
{
  pkgs,
  ...
}:

{
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
