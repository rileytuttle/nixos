# rt-dellpromax-24-only home-manager module (wired in flake.nix).
#
# The non-NixOS stand-in for modules/kanata.nix, in the same spirit as
# home/niri-generic-linux.nix. On fw12, services.kanata does three things:
#
#   1. builds a config file  (defcfg from `devices` + the shared layout)
#   2. installs a system systemd unit that runs kanata as a DynamicUser
#   3. sets up uinput        (hardware.uinput.enable -> kernel module,
#                             `uinput` group, udev rule)
#   4. puts the config somewhere a root-run kanata looks for it (/etc/kanata)
#
# This host is Ubuntu with nix as a plain package manager, so there is no
# system layer at all. (1) is done here in nix, (2) becomes a systemd *user*
# service, and (3) and (4) cannot be done by home-manager under any
# circumstances -- they are root-owned state in /etc and /dev. So both are
# handed to a script, `kanata-host-setup`, which this module puts on PATH.
# Run it once (it asks for sudo), log out and back in, done.
#
# Why a user service and not a root one: a root unit would have to hardcode a
# /nix/store path, which the next `nix-collect-garbage` is free to delete out
# from under it, leaving a broken unit and no keyboard remapping until you
# notice. home-manager rewrites the user unit on every switch and keeps the
# store path alive via the profile GC root. The cost is that kanata only runs
# while you are logged in, which for a keyboard remapper is exactly right.
{ lib, pkgs, ... }:

let
  # Which evdev devices to grab.
  #
  # Empty list = let kanata detect every keyboard-ish device and grab them
  # all. That is the right default here and it is why nothing in this repo
  # names a Dell device path: it works for the internal keyboard and for
  # whatever USB board is plugged in at the desk, with no per-dock fiddling.
  #
  # To pin specific devices instead, run `kanata --list` (kanata is on PATH
  # from home.packages below) and paste the paths in here, preferring the
  # stable /dev/input/by-id/... or by-path/... names over event numbers --
  # event numbering is assignment order and changes between boots.
  #
  #   devices = [ "/dev/input/by-path/platform-i8042-serio-0-event-kbd" ];
  devices = [ ];

  mkDevices =
    devs:
    lib.optionalString (devs != [ ])
      "linux-dev (${lib.concatStringsSep " " (map (d: "\"${d}\"") devs)})";

  # The same generation the nixpkgs NixOS module does, reimplemented because
  # that module is NixOS-only: host defcfg on top, shared layout underneath.
  #
  # linux-continue-if-no-devs-found matters more here than on fw12. With an
  # empty `devices` kanata is detecting at runtime, and on a laptop that gets
  # docked and undocked the set of keyboards changes; without this, a start
  # that happens to find nothing is a hard failure.
  kanataConfig = pkgs.writeTextFile {
    name = "kanata-config.kbd";
    text = ''
      (defcfg
        process-unmapped-keys yes
        ${mkDevices devices}
        linux-continue-if-no-devs-found yes)

      ${builtins.readFile ../dotfiles/kanataconfig.kbd}
    '';
    # Same trick as the NixOS module: a bad layout fails `home-manager switch`
    # instead of failing at login, when the keyboard is the thing you would
    # need in order to fix it.
    checkPhase = ''
      ${lib.getExe pkgs.kanata} --cfg "$target" --check --debug
    '';
  };

  # Everything root has to do on a foreign distro before an unprivileged
  # kanata can grab a keyboard and create a virtual one. This is the hand port
  # of nixpkgs' hardware/uinput.nix plus the group membership that
  # services.kanata gets for free via SupplementaryGroups.
  #
  # Note the deliberate PATH: this script edits Ubuntu's /etc and talks to
  # Ubuntu's running udevd and its user database, so it must use Ubuntu's own
  # udevadm/usermod/modprobe. A nix udevadm speaking to a different udevd
  # version is a real way to lose an afternoon.
  hostSetup = pkgs.writeShellApplication {
    name = "kanata-host-setup";
    text = ''
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin

      RULE=/etc/udev/rules.d/70-kanata-uinput.rules
      MODCONF=/etc/modules-load.d/kanata-uinput.conf
      CFGDIR=/etc/kanata
      CFGLINK=/etc/kanata/kanata.kbd

      # Written as an if, not `[ ... ] && check_only=1`: under the `set -e`
      # writeShellApplication adds, a bare failing && list exits the script.
      check_only=0
      if [ "''${1:-}" = "--check" ]; then
        check_only=1
      fi

      say()  { printf '%s\n' "$*"; }
      ok()   { printf '  ok      %s\n' "$*"; }
      bad()  { printf '  MISSING %s\n' "$*"; }

      target_user="''${KANATA_TARGET_USER:-''${SUDO_USER:-$(id -un)}}"

      # Where home-manager puts the generated config for that user. The link
      # below targets *this* path and not the /nix/store path it points at:
      # the store path changes on every layout edit and is kept alive only by
      # the home-manager profile GC root, so a direct link into the store
      # would go stale at the next switch and dangle at the next
      # nix-collect-garbage.
      #
      # `|| true` plus a fallback because writeShellApplication runs this
      # under `set -euo pipefail`: a getent that comes up empty would
      # otherwise abort the whole script here, before any of the uinput work.
      user_home="$(getent passwd "$target_user" | cut -d: -f6 || true)"
      user_cfg="''${user_home:-/home/$target_user}/.config/kanata/kanata.kbd"

      report() {
        say "kanata host prerequisites for user '$target_user':"
        if [ -e /dev/uinput ]; then ok "/dev/uinput exists"
        else bad "/dev/uinput (uinput kernel module not loaded)"; fi

        if [ -f "$RULE" ]; then ok "$RULE"
        else bad "$RULE"; fi

        if [ -f "$MODCONF" ]; then ok "$MODCONF"
        else bad "$MODCONF (uinput will not come back after a reboot)"; fi

        if getent group uinput >/dev/null 2>&1; then ok "group uinput exists"
        else bad "group uinput"; fi

        if [ ! -e "$user_cfg" ]; then
          bad "$user_cfg (run home-manager switch first)"
        elif [ -L "$CFGLINK" ] && [ "$(readlink "$CFGLINK")" = "$user_cfg" ]; then
          ok "$CFGLINK -> $user_cfg"
        else
          bad "$CFGLINK -> $user_cfg"
        fi

        for g in input uinput; do
          if id -nG "$target_user" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
            ok "$target_user is in group $g"
          else
            bad "$target_user is in group $g"
          fi
        done

        # The distinction that trips people up: being *in* a group and having
        # the group in your *current* session are different things. The
        # systemd user manager inherited its groups at login, so a fresh
        # usermod does nothing for the already-running kanata.service until
        # you log out and back in.
        uinput_gid="$(getent group uinput 2>/dev/null | cut -d: -f3 || true)"
        if [ -n "$uinput_gid" ] && id -G | tr ' ' '\n' | grep -qx "$uinput_gid"; then
          ok "current session already has the uinput group"
        else
          say "  note    this shell does not have the uinput group yet -- log out and back in"
        fi
      }

      if [ "$check_only" = 1 ]; then
        report
        exit 0
      fi

      if [ "$(id -u)" -ne 0 ]; then
        say "kanata-host-setup needs root to write udev rules and change groups."
        exec sudo KANATA_TARGET_USER="$(id -un)" "$0" "$@"
      fi

      say "==> loading the uinput kernel module"
      modprobe uinput || say "    modprobe uinput failed (built in already?); continuing"
      printf 'uinput\n' > "$MODCONF"

      say "==> creating the uinput group"
      getent group uinput >/dev/null 2>&1 || groupadd --system uinput

      say "==> installing $RULE"
      printf '%s\n' \
        '# Installed by kanata-host-setup (home/kanata-generic-linux.nix).' \
        '# Mirrors nixpkgs hardware/uinput.nix. The static_node option is what' \
        '# gives /dev/uinput the right group even before anything opens it.' \
        'SUBSYSTEM=="misc", KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"' \
        > "$RULE"

      say "==> adding $target_user to the input and uinput groups"
      usermod -aG input,uinput "$target_user"

      # Anything that starts kanata *other* than the home-manager user unit --
      # a distro package's system unit, or a bare `kanata` run as root -- looks
      # for /etc/kanata/kanata.kbd and finds nothing, because everything nix
      # installs for this host lives under $HOME. Point that path at the
      # generated config so every entry point runs the same layout.
      say "==> linking $CFGLINK -> $user_cfg"
      mkdir -p "$CFGDIR"
      if [ -e "$CFGLINK" ] && [ ! -L "$CFGLINK" ]; then
        backup="$CFGLINK.bak.$(date +%Y%m%d%H%M%S)"
        say "    $CFGLINK is a real file; moving it to $backup"
        mv "$CFGLINK" "$backup"
      fi
      ln -sfn "$user_cfg" "$CFGLINK"
      [ -e "$user_cfg" ] ||
        say "    note: $user_cfg does not exist yet -- run home-manager switch"

      say "==> reloading udev"
      udevadm control --reload-rules
      udevadm trigger --subsystem-match=misc --sysname-match=uinput

      say ""
      report
      say ""
      say "Done. Log out and back in (group changes do not reach the running"
      say "systemd user manager), then:"
      say "  systemctl --user status kanata"
    '';
  };
in
{
  home.packages = [
    pkgs.kanata     # `kanata --list` to see grabbable devices
    hostSetup       # `kanata-host-setup` / `kanata-host-setup --check`
  ];

  # Also linked into place under its default name so a bare `kanata` in a
  # terminal -- for trying a layout change before committing it -- picks up
  # the same generated config the service runs. `kanata-host-setup` points
  # /etc/kanata/kanata.kbd at this path too, for anything running as root.
  xdg.configFile."kanata/kanata.kbd".source = kanataConfig;

  systemd.user.services.kanata = {
    Unit = {
      Description = "kanata key remapper";
      Documentation = "https://github.com/jtroo/kanata";
    };

    Service = {
      Type = "notify";   # kanata speaks sd_notify; no sleep-and-hope needed
      # The store path, not ~/.config/kanata/kanata.kbd: that symlink is
      # rewritten mid-switch, and a restart racing the rewrite would read a
      # half-swapped file. home-manager restarts this unit when the path
      # changes anyway.
      ExecStart = "${lib.getExe pkgs.kanata} --cfg ${kanataConfig} --symlink-path %t/kanata/kanata --no-wait";
      RuntimeDirectory = "kanata";
      Restart = "on-failure";
      RestartSec = 2;

      # Deliberately none of the sandboxing the NixOS unit carries.
      # PrivateUsers in particular would cut this off from /dev/uinput, and
      # the hardening there leans on DynamicUser, which a user unit has no
      # equivalent for.
    };

    # default.target, not graphical-session.target: kanata works at the evdev
    # layer and is just as wanted in a tty as under niri.
    Install.WantedBy = [ "default.target" ];
  };
}
