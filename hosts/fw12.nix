{ config, pkgs, ... }:

{
  # Pull in the hardware scan NixOS generated at install time
  imports = [ ./fw12-hardware-configuration.nix ../modules/kanata.nix];

  networking.hostName = "fw12";  # whatever you want

  # WiFi is handled by NetworkManager (already enabled in common.nix)
  # but laptops often need firmware
  hardware.enableRedistributableFirmware = true;

  # Power management
  services.power-profiles-daemon.enable = false;
  services.thermald.enable = true;

  # Suspend on lid close
  services.logind.settings.Login.HandleLidSwitch = "suspend";

  # Better battery life with TLP (alternative to power-profiles-daemon)
  services.tlp.enable = true;

  # Touchpad
  services.libinput.enable = true;

  # Bluetooth
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # Screen brightness control
  users.users.rileytuttle.extraGroups = [ "video" ];  # needed for light

  # Laptop-only packages
  environment.systemPackages = with pkgs; [
    powertop
    acpi
  ];
}
