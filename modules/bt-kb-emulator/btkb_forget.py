#!/usr/bin/env python3
"""
Clear this machine's half of a Bluetooth bond.

The failure this exists for: you tap "Forget This Device" on the phone, try
to pair again, and the phone refuses -- "you need to forget it first", or it
just never completes. The phone has thrown its link key away while this PC
still holds one, so the two sides try to authenticate against a key only one
of them has. Nothing on either side says so; it looks like the phone being
stubborn. Removing our side makes the next pair a clean first-time pair.

Scope is deliberately narrow. By default it only touches addresses
hid_server.py recorded as having opened one of our HID channels (PSM
0x11/0x13), which no set of headphones, mouse or game controller ever does.
So this cannot be the reason your AirPods stop working.

    bt-kb-forget --list        what we know about, and its bond state
    bt-kb-forget               clear our side for every known HID peer
    bt-kb-forget <addr>        just that one
    bt-kb-forget --restart     ...and restart the server, ready to re-pair
"""
import argparse
import os
import re
import subprocess
import sys

import dbus

BUS_NAME = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager"

STATE_DIR = os.environ.get("BTKB_STATE_DIR", "/var/lib/bt-kb-emulator")
PEERS_PATH = os.path.join(STATE_DIR, "peers")

ADDR_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")


def known_peers():
    try:
        with open(PEERS_PATH) as f:
            return [l.strip().upper() for l in f if l.strip()]
    except FileNotFoundError:
        return []
    except OSError as exc:
        print(f"warning: cannot read {PEERS_PATH}: {exc}", file=sys.stderr)
        return []


def all_devices(bus):
    """[(device_path, adapter_path, props)] for every known BlueZ device."""
    manager = dbus.Interface(bus.get_object(BUS_NAME, "/"), OBJECT_MANAGER_IFACE)
    out = []
    for path, interfaces in manager.GetManagedObjects().items():
        props = interfaces.get(DEVICE_IFACE)
        if props is None:
            continue
        out.append((str(path), str(props.get("Adapter", "")), props))
    return out


def is_phone(props):
    """True if the Class of Device says this is a phone.

    Used only as a fallback when nothing has been recorded yet -- right after
    a fresh install the peers file is empty, and requiring --force for the
    very first clear is a bad first five minutes. Major device class 0x02 is
    Phone; headphones are 0x04 (Audio) and mice/keyboards 0x05 (Peripheral),
    so this does not widen the blast radius to them.
    """
    try:
        cls = int(props.get("Class", 0))
    except (TypeError, ValueError):
        return False
    return ((cls >> 8) & 0x1F) == 0x02


def fmt(props):
    flags = [name for name in ("Paired", "Bonded", "Trusted", "Connected") if props.get(name)]
    return ", ".join(flags) if flags else "known but not paired"


def cmd_list(bus):
    peers = known_peers()
    devices = {str(p.get("Address", "")).upper(): (path, p) for path, _, p in all_devices(bus)}

    print(f"HID peers recorded by hid_server ({PEERS_PATH}):")
    if not peers:
        print("  (none yet -- recorded when a phone first opens our HID channel)")
    for addr in peers:
        entry = devices.get(addr)
        if entry is None:
            print(f"  {addr}  no bond on this adapter (already clear)")
        else:
            _, props = entry
            name = str(props.get("Name", props.get("Alias", "?")))
            print(f"  {addr}  {name!r}: {fmt(props)}")

    others = [(a, p) for a, (_, p) in devices.items() if a not in peers and p.get("Paired")]
    if others:
        print("\nother bonded devices on this adapter:")
        for addr, props in sorted(others):
            note = "  <- would be cleared (Class says phone) only if nothing is recorded" \
                if is_phone(props) and not peers else "  left alone"
            print(f"  {addr}  {str(props.get('Name', '?'))!r}{note}")
    return 0


def remove(bus, device_path, adapter_path):
    adapter = dbus.Interface(bus.get_object(BUS_NAME, adapter_path), ADAPTER_IFACE)
    adapter.RemoveDevice(device_path)


def cmd_forget(bus, targets, force, assume_yes):
    peers = known_peers()
    devices = {str(p.get("Address", "")).upper(): (path, adapter, p)
               for path, adapter, p in all_devices(bus)}

    if targets:
        for addr in targets:
            if not ADDR_RE.match(addr):
                sys.exit(f"not a Bluetooth address: {addr!r}")
        wanted = [a.upper() for a in targets]
        unknown = [a for a in wanted if a not in peers]
        if unknown and not force:
            sys.exit(
                f"{', '.join(unknown)} is not a recorded HID peer.\n"
                "Refusing by default so this can't clear an unrelated device's "
                "pairing. Pass --force if you really mean it, or see "
                "bt-kb-forget --list."
            )
    else:
        wanted = peers
        if not wanted:
            # Nothing recorded yet. Fall back to bonded devices the Class of
            # Device identifies as phones, so a first run works without
            # --force; still confirmed before anything is removed.
            wanted = sorted(a for a, (_, _, p) in devices.items()
                            if p.get("Paired") and is_phone(p))
            if not wanted:
                print("no HID peers recorded yet, and no bonded device looks like a phone.")
                print(f"(hid_server records peers in {PEERS_PATH} as phones connect.)")
                print("Name an address explicitly if you know it: bt-kb-forget --force <addr>")
                return 0
            print(f"no HID peers recorded yet ({PEERS_PATH} is empty), so going by")
            print("Class of Device instead -- these are bonded and identify as phones.\n")

    doomed = [(a, devices[a]) for a in wanted if a in devices and devices[a][2].get("Paired")]
    if not doomed:
        print("nothing to do: none of those are bonded to this adapter.")
        return 0

    print("will clear this machine's side of the bond for:")
    for addr, (_, _, props) in doomed:
        print(f"  {addr}  {str(props.get('Name', '?'))!r}: {fmt(props)}")
    print("\nThe phone keeps its own entry; forget it there too, then pair fresh.")

    if not assume_yes:
        if not sys.stdin.isatty():
            sys.exit("not a terminal; pass --yes to confirm")
        if input("proceed? [y/N] ").strip().lower() not in ("y", "yes"):
            print("aborted")
            return 1

    failed = []
    for addr, (path, adapter, _) in doomed:
        try:
            remove(bus, path, adapter)
            print(f"  removed {addr}")
        except dbus.exceptions.DBusException as exc:
            name = exc.get_dbus_name()
            if name in ("org.freedesktop.DBus.Error.AccessDenied",
                        "org.bluez.Error.NotAuthorized"):
                sys.exit(
                    f"not allowed to remove {addr}: {exc.get_dbus_message()}\n"
                    "Re-run with sudo."
                )
            failed.append((addr, exc.get_dbus_message()))
    for addr, msg in failed:
        print(f"  FAILED {addr}: {msg}", file=sys.stderr)
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(
        description="Clear this machine's half of a stale Bluetooth bond.",
        epilog="Only recorded HID peers are touched unless --force is given.",
    )
    ap.add_argument("address", nargs="*", help="specific address(es); default is every known HID peer")
    ap.add_argument("--list", action="store_true", help="show known peers and their bond state")
    ap.add_argument("--yes", "-y", action="store_true", help="skip the confirmation prompt")
    ap.add_argument("--force", action="store_true",
                    help="allow an address that is not a recorded HID peer")
    ap.add_argument("--restart", action="store_true",
                    help="also restart bt-kb-hid-server, so you can pair straight away")
    args = ap.parse_args()

    try:
        bus = dbus.SystemBus()
    except dbus.exceptions.DBusException as exc:
        sys.exit(f"cannot reach the system bus: {exc}")

    if args.list:
        return cmd_list(bus)

    rc = cmd_forget(bus, args.address, args.force, args.yes)
    if rc == 0 and args.restart:
        # Restarting re-registers the SDP record and makes the adapter
        # discoverable again, which is what you want immediately after
        # clearing a bond.
        cmd = ["systemctl", "restart", "bt-kb-hid-server"]
        if os.geteuid() != 0:
            cmd = ["sudo", *cmd]
        print("\n$ " + " ".join(cmd))
        rc = subprocess.run(cmd).returncode
        if rc == 0:
            print("server restarted -- pair the phone now.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
