# fw12-only home-manager module (wired in flake.nix, not home/default.nix).
# Separate from home/niri.nix so DMS itself can be turned off independently
# of the niri session, in case it doesn't work out.
{ inputs, ... }:

{
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  programs.dank-material-shell = {
    enable = true;

    # Autostarted by the `spawn-at-startup "dms" "run"` line in
    # home/niri-config.kdl instead of via systemd, so leave this off to
    # avoid spawning it twice.
    systemd.enable = false;

    enableSystemMonitoring = true;
    enableDynamicTheming = true;
    enableAudioWavelength = true;

    settings = {
      theme = "dark";
      dynamicTheming = true;
    };
  };

  # Add our toggle script for Kakoune notes
  home.file.".local/bin/toggle-kakoune-notes.sh".text = builtins.readFile ./toggle-kakoune-notes.sh;
  home.file.".local/bin/toggle-kakoune-notes.sh".executable = true;
}
