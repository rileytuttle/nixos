{ pkgs, ... }:

{
  # fw12 only. The Ubuntu host (rt-dellpromax-24) gets the same layout from
  # home/kanata-generic-linux.nix, which has to rebuild this plumbing by hand
  # because there is no NixOS module layer there to do it.

  environment.systemPackages = with pkgs; [
    libinput
    evtest
    kanata   # for `kanata --list`, to see what is grabbable
  ];

  services.kanata = {
    enable = true;
    keyboards = {
      keyboard = {
        # fw12's internal keyboard. This list used to be dead config: a
        # `configFile = ../dotfiles/kanataconfig.kbd` line sat here, and per
        # the nixpkgs module a user-supplied configFile replaces the generated
        # one wholesale -- so `devices` was never consulted and the real pin
        # was a `linux-dev` line buried in the shared layout file. Now the
        # layout carries no defcfg and this list is what actually selects the
        # device.
        devices = [
          "/dev/input/by-path/platform-i8042-serio-0-event-kbd"
        ];

        # Layout only -- see the header of the file. The module wraps this in
        # a generated (defcfg ...) built from `devices` and `extraDefCfg`, and
        # because we are no longer bypassing that generation, the result is
        # also run through `kanata --check` at build time. A typo in the
        # layout is now a build failure instead of a dead keyboard.
        config = builtins.readFile ../dotfiles/kanataconfig.kbd;

        extraDefCfg = "process-unmapped-keys yes";

        # The unit is Type=notify and kanata prompts "press enter to exit" on
        # a normal exit, which a service has nobody to answer.
        extraArgs = [ "--no-wait" ];
      };
    };
  };

  # hardware.uinput.enable, the uinput group, boot.kernelModules and the
  # uinput udev rule were all spelled out here by hand. services.kanata
  # already does `hardware.uinput.enable = true`, and that module does the
  # rest -- so all of it was redundant. Likewise a SupplementaryGroups
  # override on kanata-keyboard.service: the module sets input+uinput itself,
  # and the service runs DynamicUser anyway.

  # ---------------------------------------------------------------------
  # Tablet mode: fw12 is a convertible, and a grabbed keyboard folded behind
  # the screen still reports keypresses. Stop kanata when the lid flips past
  # tablet position, start it again on the way back.
  #
  # Nothing in here applies to rt-dellpromax-24, which is not a convertible.
  # ---------------------------------------------------------------------
  environment.etc."kanata-tablet-watcher.sh" = {
    mode = "0755";
    text = ''
      #!${pkgs.bash}/bin/bash
      WAS_RUNNING_FLAG="/run/kanata-was-running"

      # Find whichever evdev node carries SW_TABLET_MODE rather than trusting
      # a fixed /dev/input/event4 -- that numbering is assignment order, so a
      # kernel bump or a USB device present at boot silently renumbers it and
      # the watcher starts querying something that is not the lid sensor.
      # evtest --query exits 10 when the switch is set, 0 when it is clear,
      # and non-zero/other when the device has no such switch at all.
      find_tablet_switch() {
        local dev rc
        for dev in /dev/input/event*; do
          [ -e "$dev" ] || continue
          ${pkgs.evtest}/bin/evtest --query "$dev" EV_SW SW_TABLET_MODE >/dev/null 2>&1
          rc=$?
          if [ $rc -eq 0 ] || [ $rc -eq 10 ]; then
            echo "$dev"
            return 0
          fi
        done
        return 1
      }

      TABLET_DEV="$(find_tablet_switch)" || {
        echo "no SW_TABLET_MODE device found; nothing to watch"
        exit 0
      }
      echo "watching tablet-mode switch on $TABLET_DEV"

      # Boot/restart straight into tablet mode: catch up to the current state
      # rather than waiting for the next transition.
      ${pkgs.evtest}/bin/evtest --query "$TABLET_DEV" EV_SW SW_TABLET_MODE
      tablet_mode_status=$?
      if [[ $tablet_mode_status -eq 10 ]] && systemctl is-active --quiet kanata-keyboard.service; then
        echo "boot up in tablet mode. pausing kanata"
        touch $WAS_RUNNING_FLAG
        systemctl stop kanata-keyboard.service
      fi

      ${pkgs.libinput}/bin/libinput debug-events 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "switch tablet-mode state 1"; then
          if systemctl is-active --quiet kanata-keyboard.service; then
            echo "kanata was running and going to tablet mode. pausing kanata"
            touch "$WAS_RUNNING_FLAG"
            systemctl stop kanata-keyboard.service
          fi

        elif echo "$line" | grep -q "switch tablet-mode state 0"; then
          if [ -f "$WAS_RUNNING_FLAG" ]; then
            echo "kanata was paused. resuming"
            rm -f "$WAS_RUNNING_FLAG"
            systemctl start kanata-keyboard.service
          fi
        fi
      done
    '';
  };

  systemd.services.kanata-tablet-watcher = {
    description = "Stop/start kanata based on tablet mode switch";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanata-keyboard.service" "systemd-udevd.service" ];

    serviceConfig = {
      ExecStart = "/etc/kanata-tablet-watcher.sh";
      Restart = "always";
      RestartSec = "2s";
      User = "root";
    };
  };

}
