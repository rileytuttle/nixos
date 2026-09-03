{ config, pkgs, inputs, ... }:

{
  # Pull in the hardware scan NixOS generated at install time
  imports = [
    ./fw12-hardware-configuration.nix
    ../modules/kanata.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
    ../modules/kde.nix
    ../modules/transmission.nix
    ../modules/steam.nix
    ../modules/nzbget.nix
    ../modules/bambustudio.nix
    ../modules/deskflow.nix
    ../modules/local-nginx.nix
    ../modules/android-tools.nix
    ../modules/niri.nix
  ];

  networking.hostName = "fw12";  # whatever you want

  # WiFi is handled by NetworkManager (already enabled in common.nix)
  # but laptops often need firmware
  hardware.enableRedistributableFirmware = true;

  # Power management
  boot.resumeDevice = "/dev/disk/by-uuid/bcddfcc6-5946-4b9d-b288-904520de5ac0";

  # Sleep/lock config stripped back to NixOS/logind defaults (no
  # mem_sleep_default override, no suspend-then-hibernate, no custom
  # IdleAction) to rule out our own tweaks while chasing the niri sleep bug.
  # Re-add pieces here once the stock behavior is confirmed working.
  boot.kernelParams = [ "mem_sleep_default=deep" ];

  services.power-profiles-daemon.enable = false;
  services.thermald.enable = true;

  # Better battery life with TLP (alternative to power-profiles-daemon)
  services.tlp.enable = true;

  # Touchpad
  services.libinput.enable = true;

  # Bluetooth
  hardware.bluetooth.enable = true;
  # services.blueman.enable = true;

  # Screen brightness control
  users.users.rileytuttle.extraGroups = [
    "video" # needed for light
    "dialout"
  ];

  # Laptop-only packages
  environment.systemPackages = with pkgs; [
    powertop
    acpi
    gnome-power-manager
    chromium
  ];

  nixpkgs.config.permittedInsecurePackages = [
      "electron-39.8.10"
  ];

  programs.kdeconnect.enable = true;
}
