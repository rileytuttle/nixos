# home-manager version, for a host where nix is only a package manager
# (Ubuntu, Fedora, Arch...) rather than the whole OS.
#
# This module can only install the user-facing half. The server itself needs
# raw AF_BLUETOOTH L2CAP sockets, which means real root -- a `systemd --user`
# service cannot host it -- and bluetoothd's `input` plugin has to be turned
# off in the system bluetooth.service. Both are root-owned system state that
# home-manager has no business writing.
#
# So the split is:
#   bt-kb-keygrab / bt-kb-send   plain user programs, installed here
#   bt-kb-setup                  run it once, it sudos and writes the two
#                                system units (see setup_system.py)
#
# Usage, on a non-NixOS host:
#   imports = [ .../bt-kb-emulator/home.nix ];
# then, once, in a shell:
#   bt-kb-setup
#
# Re-run bt-kb-setup after a home-manager update that changes this package:
# the system unit pins a /nix/store path, and `bt-kb-setup --status` reports
# when the installed unit has drifted from the current build.
#
# On NixOS, import module.nix instead -- it declares the same system state
# declaratively, and bt-kb-setup refuses to run there so the two can't fight.
{ pkgs, ... }:

let
  bt-kb-emulator = pkgs.callPackage ./package.nix { };
in
{
  home.packages = [
    bt-kb-emulator
    # bluetoothctl, for pairing and for clearing a half-gone bond
    # ("you need to forget this device first" on the phone means the PC
    # still holds the link key: bluetoothctl remove <addr>).
    pkgs.bluez
  ];
}
