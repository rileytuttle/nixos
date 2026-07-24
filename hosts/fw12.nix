{ config, pkgs, inputs, ... }:

{
  # Pull in the hardware scan NixOS generated at install time
  imports = [
    ./fw12-hardware-configuration.nix
    ../modules/kanata.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
    # ../modules/niri.nix
    ../modules/kde.nix
  ];

  networking.hostName = "fw12";  # whatever you want

  # WiFi is handled by NetworkManager (already enabled in common.nix)
  # but laptops often need firmware
  hardware.enableRedistributableFirmware = true;

  # Power management
  boot.resumeDevice = "/dev/disk/by-uuid/bcddfcc6-5946-4b9d-b288-904520de5ac0";

  # Hybrid sleep: suspends to RAM, but hibernates after delay if still sleeping
  systemd.sleep.settings.Sleep = {
    HibernateMode = "platform shutdown";
    HibernateDelaySec = "5m";
  };

  # Lid/power button behavior
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandleSuspendKey = "suspend-then-hibernate";
    HandlePowerKey = "suspend-then-hibernate";
    IdleAction = "suspend-then-hibernate";
    IdleActionSec = "5min";
  };

  services.power-profiles-daemon.enable = false;
  services.thermald.enable = true;

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
    gnome-power-manager
  ];

  nixpkgs.config.permittedInsecurePackages = [
      "electron-39.8.10"
  ];
}
