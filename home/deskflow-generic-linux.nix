# rt-dellpromax-24-only home-manager module (wired in flake.nix).
#
# The non-NixOS counterpart to modules/deskflow.nix, and deliberately not a
# port of it -- the two hosts sit on opposite ends of the deskflow link and
# fail in different portals:
#
#   fw12               client  receives input  RemoteDesktop  pkgs/niri-kdeconnect-portal
#   rt-dellpromax-24   server  sends input     InputCapture   pkgs/niri-input-portal
#
# The symptom is almost the same sentence, which is what makes this
# confusing. The server says:
#
#   ERROR: failed to initialize input capture session, quitting: CreateSession failed
#
# "input capture", not "remote desktop". The RemoteDesktop bridge fw12 uses
# does nothing here; see the header of pkgs/niri-input-portal for why niri
# supplies neither.
#
# The GlobalShortcuts warning in the same log --
#
#   WARNING: failed to create global shortcuts session, hotkeys will not be
#   forwarded: ... No such interface "org.freedesktop.portal.GlobalShortcuts"
#
# -- is a separate, cosmetic thing and is NOT fixed here. It only means
# deskflow cannot register its own hotkeys with the compositor; nothing on
# this host's niri config relies on that. Note the contrast, though: that one
# really is a missing interface, whereas InputCapture is a *failed method
# call* on an interface that exists. xdg-desktop-portal exports the
# InputCapture frontend regardless and just reports SupportedCapabilities = 0
# when nothing implements the backend, which is exactly the state this module
# fixes.
#
# Deskflow itself is NOT installed from nix here. It is the Flatpak
# (org.deskflow.deskflow), which already holds the TLS identity and the
# trusted-clients fingerprints under
# ~/.var/app/org.deskflow.deskflow/config/Deskflow -- swapping it for
# pkgs.deskflow would mean re-pairing both machines for no gain. That also
# sidesteps the one piece of fiddliness in modules/deskflow.nix: the
# RemoteDesktop bridge authorizes its caller by comparing /proc/<pid>/exe
# against a pinned store path, so it has to be rebuilt whenever deskflow is.
# This backend has no such policy -- it only logs the caller's app id -- so
# the Flatpak is accepted as-is and nothing here depends on deskflow's
# version.
{ lib, pkgs, ... }:

let
  # Not an overlay, same reasoning as modules/deskflow.nix: nothing else in
  # the tree wants it.
  niri-input-portal = pkgs.callPackage ../pkgs/niri-input-portal { };

  # The one root-level step, in the same shape as kanata-host-setup.
  #
  # xdg-desktop-portal finds backends by reading *.portal out of ONE
  # hardcoded directory and nothing else:
  #
  #   portal_dir = g_getenv ("XDG_DESKTOP_PORTAL_DIR");   /* tests only */
  #   if (portal_dir == NULL)
  #     portal_dir = DATADIR "/xdg-desktop-portal/portals";
  #
  # -- src/portal-impl.c in 1.18.x, src/xdp-portal-impl.c in 1.20.x. It does
  # NOT walk XDG_DATA_DIRS for these, and still did not as of 1.20.0; the
  # g_get_system_data_dirs() call further down that file is for portals.conf,
  # which is a different lookup. So a backend in ~/.nix-profile/share is
  # invisible no matter what XDG_DATA_DIRS says, and the whole InputCapture
  # interface then stays unexported -- xdg-desktop-portal only publishes a
  # frontend it has found an impl for, so the symptom is not a degraded
  # portal but a missing one:
  #
  #   $ busctl --user get-property org.freedesktop.portal.Desktop \
  #       /org/freedesktop/portal/desktop \
  #       org.freedesktop.portal.InputCapture SupportedCapabilities
  #   Failed to get property SupportedCapabilities on interface
  #   org.freedesktop.portal.InputCapture: No such interface ...
  #
  # Hence a copy into /usr/share. This is cheap to keep correct: the .portal
  # file is three static lines naming a D-Bus name and two interfaces, with no
  # store path in it, so it does not go stale when the package is rebuilt and
  # this only ever has to run once.
  #
  # The D-Bus service file is NOT subject to any of this -- the session bus
  # does read XDG_DATA_DIRS -- so it stays in the profile below, and that is
  # the file that actually carries the store path to the binary.
  portalSetup = pkgs.writeShellApplication {
    name = "deskflow-portal-host-setup";
    text = ''
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin

      SRC=${niri-input-portal}/share/xdg-desktop-portal/portals/niri-input.portal
      DEST=/usr/share/xdg-desktop-portal/portals/niri-input.portal

      check_only=0
      if [ "''${1:-}" = "--check" ]; then
        check_only=1
      fi

      say() { printf '%s\n' "$*"; }

      if [ "$check_only" = 1 ]; then
        say "deskflow InputCapture portal backend:"
        if [ -e "$DEST" ] && cmp -s "$SRC" "$DEST"; then
          say "  ok      $DEST is installed and current"
        elif [ -e "$DEST" ]; then
          say "  STALE   $DEST differs from $SRC"
        else
          say "  MISSING $DEST"
        fi
        exit 0
      fi

      if [ "$(id -u)" -ne 0 ]; then
        say "deskflow-portal-host-setup needs root to write $DEST."
        exec sudo "$0" "$@"
      fi

      say "==> installing $DEST"
      install -Dm644 "$SRC" "$DEST"

      cat <<'EOF'

Done. Now, as your normal user (not root):

    systemctl --user restart xdg-desktop-portal.service
    busctl --user get-property org.freedesktop.portal.Desktop \
        /org/freedesktop/portal/desktop \
        org.freedesktop.portal.InputCapture SupportedCapabilities

That should print "u 3" (keyboard | pointer). If it still says "No such
interface", xdg-desktop-portal did not pick the backend up -- check
    journalctl --user -u xdg-desktop-portal -n 50
EOF
    '';
  };
in
{
  # niri-input-portal puts the binary on PATH (the --release escape hatch
  # below wants it there) and the D-Bus service file under
  # ~/.nix-profile/share/dbus-1/services, which the session bus finds via the
  # XDG_DATA_DIRS set in home/niri-generic-linux.nix's environment.d file.
  # The .portal descriptor it also ships is NOT found that way -- see
  # portalSetup above, which is why that exists.
  home.packages = [
    niri-input-portal
    portalSetup # `deskflow-portal-host-setup` / `--check`
  ];

  # The package ships this unit too, but home-manager has no systemd.packages
  # equivalent -- it only installs units it is told about -- so declare it.
  # Upstream's install.sh writes the same thing into ~/.config/systemd/user.
  #
  # No Install section on purpose: the unit is D-Bus activated (Type=dbus +
  # BusName, and SystemdService= in the .service file above), so
  # xdg-desktop-portal starts it on the first CreateSession and it goes away
  # with the session. Enabling it would start a portal backend in every
  # session, GNOME included.
  systemd.user.services.niri-input-portal = {
    Unit = {
      Description = "InputCapture portal backend for niri";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # This box also has Ubuntu's GNOME session, where mutter supplies
      # InputCapture on its own and this backend has no business running.
      # Routing is per-desktop (niri-portals.conf below), so it would not be
      # reached there anyway, but the guard also keeps it from being started
      # from a plain ssh/tty session with no display.
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "dbus";
      BusName = "org.freedesktop.impl.portal.desktop.niri-input";
      ExecStart = lib.getExe niri-input-portal;
      Restart = "on-failure";
      RestartSec = 1;
      Slice = "session.slice";
    };
  };

  # fw12 gets the equivalent through the NixOS option
  # `xdg.portal.config.niri."org.freedesktop.impl.portal.RemoteDesktop"`.
  # Standalone home-manager has no xdg.portal module, so write the file that
  # option would have generated. xdg-desktop-portal looks for
  # "<XDG_CURRENT_DESKTOP>-portals.conf" lowercased, and niri's session sets
  # XDG_CURRENT_DESKTOP=niri -- so this is read under niri and nowhere else,
  # which is what keeps Ubuntu's GNOME session on this box untouched.
  #
  # Clipboard has to be routed here too, and it is not optional. The clipboard
  # portal attaches to a session some other portal created, so if it lands on
  # a different backend that backend is asked about a session it has never
  # heard of; RequestClipboard fails, deskflow throws the session away and
  # opens a new one, and it never gets as far as capturing.
  #
  # Clipboard sharing still will not actually work on this host yet -- see the
  # version note at the bottom of this file -- but the routing is what stops
  # the create/destroy loop, so it belongs here regardless.
  #
  # `default` repeats xdg-desktop-portal's existing behaviour explicitly
  # rather than changing it: niri implements Mutter's ScreenCast and
  # Shell.Screenshot APIs, so xdg-desktop-portal-gnome serves ScreenCast and
  # Screenshot here, with gtk behind it for FileChooser and friends.
  xdg.configFile."xdg-desktop-portal/niri-portals.conf".text = ''
    [preferred]
    default=gnome;gtk;
    org.freedesktop.impl.portal.InputCapture=niri-input;
    org.freedesktop.impl.portal.Clipboard=niri-input;
  '';

  # NOT handled here, and it matters: the escape hatch for a stuck capture.
  # While a capture is active the keyboard is grabbed and the pointer is
  # locked, so nothing inside the backend can free it -- it has to be a niri
  # binding, because niri resolves its own bindings before clients see them.
  # It goes in ~/.config/niri/local.kdl (the unmanaged host-specific file
  # home/niri-config.kdl pulls in with `include optional=true`), because
  # niri-config.kdl itself is shared with fw12, which has no such binary:
  #
  #   binds {
  #       Mod+Shift+Escape allow-inhibiting=false {
  #           spawn "/home/rileytuttle/.nix-profile/bin/niri-input-portal" "--release";
  #       }
  #   }
  #
  # Spelled out in full on purpose: niri's `spawn` execs directly, with no
  # shell, so "~/..." would be passed through as a literal and fail -- the
  # same reason Mod+P in home/niri-config.kdl names its script absolutely.
  # (`spawn "niri-input-portal"` would also resolve, via the environment.d
  # PATH, but an escape hatch should not depend on that having been applied.)
  #
  # There is a 15s idle timeout as a backstop
  # (NIRI_INPUT_PORTAL_IDLE_TIMEOUT), but do not rely on it.
  #
  # KNOWN GAP -- Ubuntu 24.04 ships xdg-desktop-portal 1.18.4, while this
  # backend is developed against 1.20.4+ and clipboard sharing needs the
  # frontend changes that only landed in 1.21.1 (before that the frontend
  # gated clipboard access on the session being a *RemoteDesktop* session, so
  # deskflow's request comes back as "Invalid session type" and it logs
  # "clipboard not enabled on session"). The backend implements both
  # InputCapture interface versions, so 1.18.4 should negotiate v1 and get
  # capture; shared clipboard between the two machines will not work until
  # this host moves past 24.04. Nothing to do about it from nix --
  # xdg-desktop-portal is Ubuntu's here, and replacing the whole portal stack
  # with nix's for one feature is not worth the blast radius.
}
