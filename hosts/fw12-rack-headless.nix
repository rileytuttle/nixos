{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./fw12-rack-headless-hardware-configuration.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
  ];

  networking.hostName = "fw12-rack-headless";

  # This is fw12's original mainboard -- 13th-gen Intel (Raptor Lake), i915
  # iGPU, no NPU -- pulled when fw12 itself moved to the Core Series 3 board
  # (see hosts/fw12.nix). Reused here headless in a server rack rather than
  # thrown out. The nixos-hardware module for it is pulled in by flake.nix.
  hardware.enableRedistributableFirmware = true;

  # Headless: no monitor plugged in, no desktop session to run. common.nix
  # turns xserver/sddm/plasma6 on unconditionally (fine for fw12 and
  # elitedesk, which both have a screen); override all three off here rather
  # than build and never use one.
  services.xserver.enable = lib.mkForce false;
  services.displayManager.sddm.enable = lib.mkForce false;
  services.desktopManager.plasma6.enable = lib.mkForce false;

  # No battery, lid, touchpad or Bluetooth peripherals on a board sitting in
  # a rack chassis on wall power -- none of fw12.nix's laptop power
  # management (TLP/thermald/sleep-hibernate/bluetooth/libinput/kdeconnect)
  # applies here.
}
