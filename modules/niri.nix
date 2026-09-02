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

  # DMS (dank-material-shell.nix) owns idle detection, auto-lock/suspend,
  # and the lock screen itself — it's meant to replace swayidle+swaylock,
  # not run alongside them. Configure idle timeout/auto-lock in DMS's own
  # Settings UI (lock_screen / power_sleep tabs, Mod+Shift+Comma).
  #
  # These settings live in DMS's own state, not in this repo, so they
  # aren't reset by a nix rebuild — while chasing the sleep bug, disable
  # DMS's idle timeout/auto-lock/auto-suspend there by hand too, so niri's
  # own Mod+Shift+P (power-off-monitors) and logind's stock lid/suspend/
  # power-key handling are the only things left in the loop.

  environment.systemPackages = with pkgs; [
    fuzzel
    wl-clipboard
  ];
}
