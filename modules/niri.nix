{ config, pkgs, ... }:

{
  # `programs.niri.enable` (native nixpkgs module, no flake needed) just
  # registers niri as a selectable session with whatever display manager is
  # already running (SDDM, for Plasma here). It shows up as an extra option
  # at the login screen — Plasma stays the default, untouched.
  programs.niri.enable = true;

  security.polkit.enable = true;

  # niri-session sets up its own PATH; don't let NixOS's default
  # systemd Environment= clobber it (breaks spawn actions otherwise).
  systemd.user.services.niri.enableDefaultPath = false;

  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "polkit-gnome-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
  };

  systemd.user.services.swayidle = {
    description = "Idle manager for Wayland";
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.swayidle}/bin/swayidle -w \
          timeout 300 '${pkgs.swaylock}/bin/swaylock' \
          before-sleep '${pkgs.swaylock}/bin/swaylock' \
      '';
      Restart = "on-failure";
    };
  };

  environment.systemPackages = with pkgs; [
    fuzzel
    swaylock
    swayidle
    wl-clipboard
  ];
}
