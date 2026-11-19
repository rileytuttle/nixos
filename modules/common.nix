{
  lib,
  config,
  pkgs,
  ...
}:

{

  imports = [
    ./kakoune.nix
  ];

  # Nix settings
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
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

  # mDNS, so LAN hosts are reachable as <hostname>.local. Without this
  # nothing on the box answers .local at all: systemd-resolved is off, so
  # there is no fallback multicast resolver, and a .local lookup falls
  # through nsswitch to unicast DNS at the router, which NXDOMAINs it.
  #
  # nssmdns4 is the half that matters for *resolving*: it is what puts
  # mdns_minimal into nsswitch.conf's hosts line. With the daemon enabled
  # but nssmdns4 off, avahi runs and glibc never asks it anything.
  #
  # publish is the other direction -- this host answering for its own name
  # so the rest of the LAN can find it. Every host built from this repo
  # needs it for the same reason; devices that aren't ours (printers,
  # phones, Macs) already publish on their own.
  #
  # openFirewall defaults to true and opens UDP 5353, so it is left unset.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

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
  services.displayManager.defaultSession = lib.mkForce "plasma";

  # Your user account
  users.users.rileytuttle = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
    ];
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
