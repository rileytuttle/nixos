# niri-dms.nix
#
# Enables niri (native nixpkgs 26.05 package, no flake needed) as the
# session compositor, then layers DankMaterialShell on top of it via
# home-manager.
#
# Requires:
#   - nixpkgs pinned to nixos-26.05 or newer (niri is native there)
#   - home-manager already wired in as a NixOS module
#   - `inputs` passed through specialArgs so `inputs.dms` is reachable here
#
# Usage in configuration.nix:
#
#   imports = [ ./niri-dms.nix ];
#
# Usage in flake.nix (inputs + specialArgs), add alongside your existing
# nixpkgs/home-manager inputs:
#
#   inputs.dms = {
#     url = "github:AvengeMedia/DankMaterialShell/stable";
#     inputs.nixpkgs.follows = "nixpkgs";
#   };
#
#   nixosConfigurations.fw12 = nixpkgs.lib.nixosSystem {
#     specialArgs = { inherit inputs; };   # <- make sure this line exists
#     modules = [ ./configuration.nix ];
#   };
#
# Adjust `username` below to match the user DMS should run under.

{ config, pkgs, inputs, ... }:

let
  username = "rileytuttle";
in
{
  # --- Compositor -----------------------------------------------------

  programs.niri.enable = true;

  # No display-manager config here on purpose: `programs.niri.enable`
  # registers niri as a selectable session with whatever display manager
  # you already have running (SDDM, for Plasma). It'll just show up as an
  # extra option at the login screen — Plasma stays the default, untouched.

  # niri-session sets up its own PATH; don't let NixOS's default
  # systemd Environment= clobber it (breaks spawn actions otherwise).
  systemd.user.services.niri.enableDefaultPath = false;

  # --- DankMaterialShell, layered on niri ------------------------------

  home-manager.users.${username} = {
    imports = [
      inputs.dms.homeModules.dank-material-shell
      inputs.dms.homeModules.niri
    ];

    programs.dank-material-shell = {
      enable = true;

      niri = {
        enableKeybinds = true; # preset keybinds: launcher, notifications, settings, etc.
        enableSpawn = true;    # auto-start DMS alongside niri
      };

      # Only one auto-start method should be active — using niri.enableSpawn
      # above, so systemd-based startup stays off to avoid double-spawning.
      systemd.enable = false;

      enableSystemMonitoring = true;
      enableDynamicTheming = true;
      enableAudioWavelength = true;

      settings = {
        theme = "dark";
        dynamicTheming = true;
      };
    };
  };
}
