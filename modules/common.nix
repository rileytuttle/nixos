{ config, pkgs, ... }:

{

  imports = [
    ./kakoune.nix
  ];

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # Bootloader (both machines use systemd-boot + EFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Locale / time
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Networking (hostname is set per-host)
  networking.networkmanager.enable = true;

  # Sound
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Display server
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # Your user account
  users.users.rileytuttle = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
  };

  # Global packages available to all users
  environment.systemPackages = with pkgs; [
    wget
    curl
  ];

  # Allow unfree packages (needed for things like VSCode, nvidia drivers)
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
}
