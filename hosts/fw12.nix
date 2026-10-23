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
    ../modules/smart-sleep.nix
    ../modules/docker.nix
    ../modules/kicad.nix
  ];

  networking.hostName = "fw12";  # whatever you want

  # WiFi is handled by NetworkManager (already enabled in common.nix)
  # but laptops often need firmware
  hardware.enableRedistributableFirmware = true;

  # Suspend first, then hibernate to disk if still asleep after
  # HibernateDelaySec. Short enough that a closed lid in a bag doesn't
  # drain the battery, long enough that closing the lid to walk across the
  # room still resumes instantly from RAM.
  #
  # Every way of getting here (lid, DMS power menu, DMS idle timeout) goes
  # through `smart-sleep suspend-then-hibernate`, which closes Bitwarden
  # first -- its secret memory blocks hibernation kernel-wide. See
  # modules/smart-sleep.nix.
  systemd.sleep.settings.Sleep = {
    HibernateMode = "platform shutdown";
    HibernateDelaySec = "5min";
  };

  # Power management
  boot.resumeDevice = "/dev/disk/by-uuid/bcddfcc6-5946-4b9d-b288-904520de5ac0";

  # boot.kernelParams = [ "mem_sleep_default=deep" ];

  # DMS idle/power-menu actions. Suspend behavior stays "Suspend" (0) on
  # purpose: DMS's own SuspendThenHibernate behavior calls systemctl
  # directly and ignores customPowerActionSuspend, which would skip
  # closing Bitwarden. Timeouts are in seconds.
  home-manager.users.rileytuttle.programs.dank-material-shell.settings = {
    customPowerActionSuspend = "smart-sleep suspend-then-hibernate";
    customPowerActionHibernate = "smart-sleep hibernate";
    lockBeforeSuspend = true;
    batteryLockTimeout = 300;
    batterySuspendTimeout = 600;
    batterySuspendBehavior = 0;
    acLockTimeout = 900;
    acSuspendTimeout = 1800;
    acSuspendBehavior = 0;
  };

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
