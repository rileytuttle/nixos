# Bluetooth HID-device keyboard emulator: pairs this PC to a phone as a
# Bluetooth keyboard peripheral. See README.md in this directory for the
# protocol writeup (BlueZ only handles pairing/SDP here; the two raw L2CAP
# sockets for the actual keystroke traffic are owned directly by
# hid_server.py).
{ lib, pkgs, ... }:

let
  # Shared with home.nix (home-manager on a foreign distro), which installs
  # the same programs but has bt-kb-setup write the system units imperatively.
  bt-kb-emulator = pkgs.callPackage ./package.nix { };
in
{
  hardware.bluetooth.enable = true;

  # REQUIRED, and the one invasive thing this module does. bluetoothd's
  # `input` plugin is the HID *host* role (this PC driving an external
  # Bluetooth keyboard/mouse) and it binds L2CAP PSM 0x11 and 0x13 on the
  # adapter address for every adapter, unconditionally, as soon as it
  # loads -- see profiles/input/server.c:server_probe() in the bluez
  # source. Those are exactly the two PSMs the HID *device* role needs, so
  # hid_server.py cannot bind them while the plugin is loaded, and even
  # binding BDADDR_ANY alongside it loses: the kernel's
  # l2cap_global_chan_by_psm() prefers the channel whose source address
  # matches the adapter exactly over a BDADDR_ANY wildcard, so bluetoothd
  # would silently swallow every incoming connection from the phone.
  #
  # The cost: this machine can no longer act as a Bluetooth HID host, i.e.
  # no external Bluetooth keyboards or mice. Audio, networking and
  # everything else are untouched. Drop this line (and lose the emulator)
  # if you'd rather keep BT input devices.
  #
  # NixOS turns this into `bluetoothd --noplugin=input`. Note the BlueZ
  # docs/old tutorials suggest `DisablePlugins` in main.conf -- that is not
  # a main.conf key in BlueZ 5.x (see the accepted-key list in src/main.c),
  # only the -P/--noplugin command line flag works.
  hardware.bluetooth.disabledPlugins = [ "input" ];

  # nixpkgs hardcodes `restartIfChanged = false` on bluetooth.service
  # (services/hardware/bluetooth.nix) because "restarting can leave people
  # without a mouse/keyboard" -- so switching to a config that adds
  # --noplugin=input leaves the OLD bluetoothd running, still holding the HID
  # UUID and PSM 0x11/0x13, and bt-kb-hid-server fails with "UUID already
  # registered" until you remember to restart it by hand. mkForce because
  # that false is a plain assignment, not an mkDefault.
  #
  # The reasoning behind the nixpkgs default doesn't apply to us anyway:
  # disabledPlugins above has already given up Bluetooth HID host support, so
  # there is no Bluetooth mouse or keyboard left for a restart to drop.
  systemd.services.bluetooth.restartIfChanged = lib.mkForce true;

  # Class of Device, so the phone shows a keyboard icon and doesn't filter
  # us out of its scan results: major device class 0x05 (Peripheral),
  # minor 0x40 (keyboard). This replaces the manual `btmgmt class` step --
  # `Class` is a real main.conf key, and bluetoothd only honours the major
  # and minor device class bits, so the service class bits are left zero.
  hardware.bluetooth.settings.General.Class = "0x000540";

  environment.systemPackages = [
    bt-kb-emulator
    pkgs.bluez
  ];

  # Not started at boot, on purpose: the pairing agent auto-accepts any
  # nearby pairing request for as long as the adapter is discoverable, so
  # an always-on service means that window is always open. Start it by
  # hand right before pairing, then run the capture window as yourself:
  #   sudo systemctl start bt-kb-hid-server
  #   bt-kb-keygrab
  # Clearing a stale bond is `bt-kb-forget` (from the package above):
  #   bt-kb-forget --list       what we hold, and what it won't touch
  #   bt-kb-forget --restart    clear our half, restart the server
  # It only ever clears bonds for devices that actually connected to our HID
  # channels, recorded in /var/lib/bt-kb-emulator/peers.
  systemd.services.bt-kb-hid-server = {
    description = "Bluetooth HID-device keyboard emulator server";

    # A `nixos-rebuild switch` must NOT restart this. Restarting closes the
    # L2CAP sockets under a connected phone, the phone drops off, and the
    # usual way out of that is forgetting the device on the phone -- which
    # leaves the bond half-gone (removed there, still here) and the next
    # pair attempt refused. So every unrelated rebuild could cost a re-pair.
    #
    # Nothing is lost by leaving the old process running: the service is
    # started by hand right before pairing anyway (see below), so restarting
    # it to pick up a new build is a deliberate act:
    #   sudo systemctl restart bt-kb-hid-server
    restartIfChanged = false;
    stopIfChanged = false;
    # dbus.service as well as bluetooth.service: the server talks to
    # bluetoothd over the system bus before it binds anything, so an
    # unavailable bus is an immediate hard failure rather than a retry.
    after = [
      "bluetooth.service"
      "dbus.service"
    ];
    requires = [ "bluetooth.service" ];

    # Intentionally unsandboxed: raw AF_BLUETOOTH L2CAP sockets and the
    # system D-Bus need real root and an un-namespaced network/HCI view.
    # Do not add DynamicUser, PrivateNetwork, or ProtectKernelTunables
    # here -- they break the Bluetooth socket calls.
    serviceConfig = {
      Type = "simple";
      # The SDP record is registered by hid_server.py itself over D-Bus
      # (ProfileManager1.RegisterProfile) -- modern bluetoothd's sdptool
      # dropped `add --xml` for arbitrary records, so there is no separate
      # ExecStartPre step here.
      ExecStart = "${bt-kb-emulator}/bin/bt-kb-hid-server";
      Restart = "on-failure";
      RestartSec = 2;
      # Exit 78 (EX_CONFIG) is hid_server.py saying the environment is wrong
      # -- input plugin still loaded, not root, PSM taken. None of that heals
      # on its own, so restarting just spins at RestartSec forever and buries
      # the real error under thousands of identical journal lines.
      RestartPreventExitStatus = 78;
    };
    # Belt and braces for the genuinely transient failures that do restart.
    startLimitIntervalSec = 60;
    startLimitBurst = 5;
  };
}
