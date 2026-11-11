#!/usr/bin/env python3
"""
Non-interactive keystroke sender -- the thing to reach for when "I type and
nothing appears on the phone" and you need to know which half is broken.

keygrab.py puts a Tk window, X11/XWayland key events and a keymap between you
and the Bluetooth link. This puts nothing there: it talks straight to
hid_server.py's Unix socket, so if `btkb-send hello` types on the phone the
whole HID path is fine and the problem is in the capture window, and if it
doesn't, the capture window was never the problem.

    bt-kb-send --status           is a phone actually connected?
    bt-kb-send hello world        type a string
    bt-kb-send --key Return       press one key by keysym name
"""
import argparse
import json
import os
import socket
import sys
import time

from hid_keymap import MODIFIER_MASK, MOD_LEFT_SHIFT, usage_for_char, usage_for_keysym

IPC_SOCKET_PATH = os.environ.get("BTKB_IPC", "/run/btkb-hid.sock")


class Sender:
    def __init__(self, path, delay):
        self.delay = delay
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
        except OSError as exc:
            sys.exit(
                f"cannot reach hid_server at {path}: {exc}\n"
                "Is bt-kb-hid-server running? systemctl status bt-kb-hid-server"
            )
        self.sock.settimeout(2.0)
        self._buf = b""

    def read_status(self):
        """hid_server pushes {"link": bool} on connect and on every change."""
        try:
            while b"\n" not in self._buf:
                chunk = self.sock.recv(4096)
                if not chunk:
                    return None
                self._buf += chunk
        except (TimeoutError, OSError):
            return None
        line, self._buf = self._buf.split(b"\n", 1)
        try:
            return json.loads(line)
        except ValueError:
            return None

    def report(self, mods, keys):
        self.sock.sendall((json.dumps({"mods": mods, "keys": keys}) + "\n").encode())
        time.sleep(self.delay)

    def tap(self, usage, mods=0):
        self.report(mods, [usage])
        self.report(mods, [])

    def type_text(self, text):
        unmapped = set()
        for ch in text:
            mapped = usage_for_char(ch)
            if mapped is None:
                unmapped.add(ch)
                continue
            usage, shift = mapped
            self.tap(usage, MOD_LEFT_SHIFT if shift else 0)
        # Always release everything, so an interrupted run can't leave a key
        # held down on the phone.
        self.report(0, [])
        if unmapped:
            print(f"skipped unmapped characters: {sorted(unmapped)}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="Send keystrokes to the paired phone.")
    ap.add_argument("text", nargs="*", help="text to type (words are space-joined)")
    ap.add_argument("--key", action="append", default=[],
                    help="press one key by keysym name, e.g. Return, Tab, F5 (repeatable)")
    ap.add_argument("--status", action="store_true",
                    help="report whether a phone's interrupt channel is connected, then exit")
    ap.add_argument("--delay", type=float, default=0.012,
                    help="seconds between reports (default 0.012)")
    ap.add_argument("--newline", action="store_true", help="press Return after the text")
    args = ap.parse_args()

    sender = Sender(IPC_SOCKET_PATH, args.delay)
    status = sender.read_status()
    linked = bool(status and status.get("link"))

    if args.status:
        if status is None:
            print("link: unknown (no status from hid_server)")
            return 2
        print(f"link: {'connected' if linked else 'NOT connected'}")
        return 0 if linked else 1

    if not linked:
        print(
            "No phone connected: hid_server has no interrupt channel, so every\n"
            "report would be dropped. Connect the phone to 'Linux Keyboard'\n"
            "first, then check: journalctl -u bt-kb-hid-server -f",
            file=sys.stderr,
        )
        return 1

    if args.text:
        sender.type_text(" ".join(args.text))
    for name in args.key:
        usage = usage_for_keysym(name)
        if usage is None:
            if name in MODIFIER_MASK:
                print(f"{name} is a modifier; use it with text instead", file=sys.stderr)
            else:
                print(f"unknown keysym {name!r}", file=sys.stderr)
            return 2
        sender.tap(usage)
    if args.newline:
        sender.tap(usage_for_keysym("Return"))
    if not args.text and not args.key and not args.newline:
        ap.error("nothing to send -- give text, --key, or --status")
    return 0


if __name__ == "__main__":
    sys.exit(main())
