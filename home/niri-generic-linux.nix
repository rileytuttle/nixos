# rt-dellpromax-24-only home-manager module (wired in flake.nix).
#
# This is the non-NixOS stand-in for modules/niri.nix. On fw12, niri is
# delivered in two layers: a system layer (modules/niri.nix -> the binary,
# the SDDM session entry, polkit, fuzzel, wl-clipboard) and a home layer
# (home/niri.nix + home/dank-material-shell.nix). rt-dellpromax-24 is
# Ubuntu with nix as a plain package manager, so there is no system layer
# to speak of: niri itself is built from source and installed into
# /usr/local by scripts/install-niri-from-source.sh (which also registers
# /usr/local/share/wayland-sessions/niri.desktop with gdm), and this
# file re-creates the userland bits modules/niri.nix was installing
# system-wide.
#
# Kept separate from home/niri.nix so the shared niri config stays
# host-agnostic and fw12 is untouched. Host-specific KDL goes in the
# local.kdl written below, via the `include optional=true "local.kdl"`
# hook already at the end of home/niri-config.kdl.
{ config, pkgs, ... }:

let
  # Which nixGL wrapper DMS runs under.
  #
  # niri is built from source against Ubuntu's own mesa, so it needs no
  # wrapping. DMS does not get that luxury: it's Quickshell (Qt6/QML) from
  # nix, so it links *nix's* libEGL, which cannot find Ubuntu's GL driver.
  # Unwrapped it starts, initialises its Go backend fine, and then dies at
  # the point it tries to paint:
  #
  #   QRhiGles2: Failed to create temporary context
  #   Failed to create QRhi on the render thread; scenegraph is not functional
  #   Failed to create graphics context for qs::wayland::layershell::WlrLayershell
  #
  # WlrLayershell is the bar, so the symptom is "no top bar" — and no
  # launcher either, since Mod+Space's `dms ipc spotlight toggle` reaches a
  # live process that then fails to render another layer-shell surface.
  #
  # nixGLIntel is the mesa wrapper; despite the name it covers AMD too, and
  # it evaluates purely. On the NVIDIA proprietary driver, swap this for
  #   "${pkgs.nixgl.auto.nixGLNvidia}/bin/nixGLNvidia"
  # which sniffs the running driver version at eval time and therefore needs
  # `home-manager switch --impure`.
  nixGLBin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";
in
{
  # The key non-NixOS switch: fixes up XDG_DATA_DIRS and friends so nix's
  # .desktop files, icons and portal definitions coexist with /usr/share.
  targets.genericLinux.enable = true;

  # Without this, nix-installed apps can't find nix-installed fonts on a
  # foreign distro. DMS in particular ships its own Material Symbols font.
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    # These two were environment.systemPackages in modules/niri.nix.
    fuzzel        # Mod+D
    wl-clipboard

    swaylock      # Mod+Alt+L — referenced by niri-config.kdl, installed nowhere else
    polkit_gnome  # for the user service below
    jq            # toggle-kakoune-notes.sh needs it (normally from home/default.nix)
  ];

  # Ported from modules/niri.nix. Note home-manager wants capitalised
  # systemd section attrs (Unit/Service/Install), unlike the NixOS module.
  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    Unit = {
      Description = "polkit-gnome-authentication-agent-1";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Load-bearing. niri-config.kdl spawns bare `dms`, `fuzzel`, `swaylock`,
  # all of which live in ~/.nix-profile/bin. gdm execs a Wayland session
  # directly and does NOT source ~/.profile, so without this PATH would be
  # systemd's stock one and every spawn would silently fail. niri-session
  # does `systemctl --user import-environment` and starts niri.service, and
  # the systemd user manager reads ~/.config/environment.d/*.conf.
  #
  # This is the stand-in for fw12's
  # `systemd.user.services.niri.enableDefaultPath = false` — that option is
  # NixOS-only, and the niri.service shipped by the source build sets no
  # Environment=PATH to disable.
  #
  # ~/.local/bin goes FIRST so the dms shim below shadows the real dms in
  # ~/.nix-profile/bin. Order is load-bearing here, not cosmetic.
  xdg.configFile."environment.d/95-nix-profile.conf".text = ''
    PATH=${config.home.homeDirectory}/.local/bin:${config.home.homeDirectory}/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin
    XDG_DATA_DIRS=${config.home.homeDirectory}/.nix-profile/share:/usr/local/share:/usr/share
  '';

  # The nixGL shim. home/niri-config.kdl is shared with fw12 and spawns a
  # bare `dms`, so the wrapping has to happen via PATH rather than by editing
  # the spawn line — otherwise fw12 (NixOS, no nixGL needed) would break.
  #
  # This also catches the `dms ipc ...` calls from the keybinds. Those don't
  # render anything themselves, but routing every entry point through one
  # wrapper is cheaper to reason about than special-casing `run`.
  home.file.".local/bin/dms" = {
    executable = true;
    text = ''
      #!/bin/sh
      exec ${nixGLBin} ${config.home.profileDirectory}/bin/dms "$@"
    '';
  };

  # NOTE: ~/.config/niri/local.kdl is deliberately NOT managed here, same as
  # on fw12. It's the unmanaged scratch file pulled in by the
  # `include optional=true "local.kdl"` line at the end of
  # home/niri-config.kdl — hand-edited, niri live-reloads on save, no rebuild
  # needed. Host-specific display/output settings for this machine go there.
}
