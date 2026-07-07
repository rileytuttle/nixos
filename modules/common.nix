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
    wireplumber.enable = true;
  };

  # Display server
  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Your user account
  users.users.rileytuttle = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
  };

  # Global packages available to all users
  environment.systemPackages = with pkgs; [
    wget
    curl
    git
    gnome-terminal
  ];

  fonts.packages = with pkgs; [
    jetbrains-mono
    noto-fonts
    noto-fonts-color-emoji
  ];


  # Allow unfree packages (needed for things like VSCode, nvidia drivers)
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
}
