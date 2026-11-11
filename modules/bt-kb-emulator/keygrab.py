#!/usr/bin/env python3
"""
xev-like capture window. Run as your normal desktop user (no root needed).

While armed (green/LIVE), every key press/release in this window is
translated to a USB HID usage code and streamed to hid_server.py over a
Unix socket, which forwards it to the paired phone as a Bluetooth keyboard
report.

F12 toggles armed/paused and is never itself forwarded -- it's intercepted
before reaching the keymap, since Escape (a key you DO want to send to the
phone) can't double as the "stop capturing" sequence. Losing focus also
auto-pauses and releases any held keys, so alt-tabbing away mid-keypress
can't leave a key stuck down on the phone.
"""
import json
import os
import socket
import tkinter as tk

from hid_keymap import MODIFIER_MASK, usage_for_keysym

IPC_SOCKET_PATH = os.environ.get("BTKB_IPC", "/run/btkb-hid.sock")


class KeyGrabApp:
    def __init__(self, root):
        self.root = root
        self.armed = False
        self.modifier_byte = 0
        self.pressed_usages = []  # ordered, HID boot protocol supports up to 6
        self.sock = None
        self._rxbuf = b""

        root.title("bt-kb-emulator")
        root.geometry("480x260")

        self.status = tk.Label(root, font=("sans-serif", 16, "bold"), pady=20)
        self.status.pack(fill="x")
        self.status.bind("<Button-1>", lambda e: self.toggle_armed())

        # Separate from `status`: armed/paused is about THIS window, link is
        # about whether a phone is on the other end. Conflating them is how
        # you end up typing happily into a window that says LIVE while
        # hid_server has no interrupt channel and is dropping every report.
        self.link = tk.Label(root, font=("sans-serif", 11), pady=4)
        self.link.pack(fill="x")

        self.lastkey = tk.Label(root, font=("monospace", 12), pady=10)
        self.lastkey.pack(fill="x")

        hint = tk.Label(
            root,
            text="F12 or click the status bar to arm/pause.\n"
                 "Losing focus auto-pauses and releases held keys.",
            font=("sans-serif", 10),
            fg="#666666",
        )
        hint.pack(fill="x", pady=10)

        root.bind("<KeyPress>", self.on_key_press)
        root.bind("<KeyRelease>", self.on_key_release)
        root.bind("<FocusOut>", self.on_focus_out)

        self.linked = None  # None = unknown, before the first status line
        self._render_state()
        self._render_link()
        self._connect_ipc()
        self._poll_status()

    def _connect_ipc(self):
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(IPC_SOCKET_PATH)
            self.sock.setblocking(False)
            self._rxbuf = b""
        except OSError as exc:
            self.sock = None
            self.linked = None
            self.lastkey.config(text=f"(not connected to hid_server: {exc})")
            self._render_link()

    def _poll_status(self):
        """Drain any {"link": bool} lines hid_server pushed at us.

        Non-blocking and on the Tk timer rather than a reader thread: Tk
        widgets may only be touched from the thread running the mainloop.
        """
        if self.sock is not None:
            try:
                while True:
                    chunk = self.sock.recv(4096)
                    if not chunk:
                        raise OSError("hid_server closed the connection")
                    self._rxbuf += chunk
            except BlockingIOError:
                pass
            except OSError:
                self.sock = None
                self.linked = None
                if self.armed:
                    self.armed = False
                    self._render_state()

            while b"\n" in self._rxbuf:
                line, self._rxbuf = self._rxbuf.split(b"\n", 1)
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if "link" in msg:
                    self.linked = bool(msg["link"])
            self._render_link()

        self.root.after(400, self._poll_status)

    def _render_link(self):
        if self.sock is None:
            self.link.config(text="hid_server: not connected", fg="#c62828")
        elif self.linked is None:
            self.link.config(text="phone: waiting for status\u2026", fg="#666666")
        elif self.linked:
            self.link.config(text="phone: connected", fg="#2e7d32")
        else:
            self.link.config(
                text="phone: NOT connected \u2014 keystrokes are being dropped",
                fg="#c62828",
            )

    def _send_state(self):
        if self.sock is None:
            self._connect_ipc()
            if self.sock is None:
                return
        msg = json.dumps({"mods": self.modifier_byte, "keys": self.pressed_usages[:6]}) + "\n"
        try:
            self.sock.sendall(msg.encode())
        except BlockingIOError:
            # Socket is non-blocking (see _poll_status) and the send buffer is
            # momentarily full. Reports are 40-odd bytes and hid_server drains
            # continuously, so this is a lost keystroke at worst -- not a
            # reason to tear down a working connection.
            pass
        except OSError:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
            self.linked = None
            self._render_link()

    def _render_state(self):
        if self.armed:
            self.status.config(text="LIVE -- sending to phone", bg="#2e7d32", fg="white")
        else:
            self.status.config(text="PAUSED", bg="#c62828", fg="white")

    def toggle_armed(self):
        self.armed = not self.armed
        if not self.armed:
            self._release_all()
        self._render_state()

    def _release_all(self):
        self.modifier_byte = 0
        self.pressed_usages = []
        self._send_state()

    def on_focus_out(self, _event):
        if self.armed:
            self.armed = False
            self._release_all()
            self._render_state()

    def on_key_press(self, event):
        if event.keysym == "F12":
            self.toggle_armed()
            return "break"

        if not self.armed:
            return

        self.lastkey.config(text=f"down: {event.keysym}")

        if event.keysym in MODIFIER_MASK:
            self.modifier_byte |= MODIFIER_MASK[event.keysym]
            self._send_state()
            return "break"

        usage = usage_for_keysym(event.keysym)
        if usage is not None and usage not in self.pressed_usages:
            self.pressed_usages.append(usage)
            self._send_state()
        return "break"

    def on_key_release(self, event):
        if event.keysym == "F12":
            return "break"  # press already toggled; ignore the release

        if not self.armed:
            return

        self.lastkey.config(text=f"up:   {event.keysym}")

        if event.keysym in MODIFIER_MASK:
            self.modifier_byte &= ~MODIFIER_MASK[event.keysym]
            self._send_state()
            return "break"

        usage = usage_for_keysym(event.keysym)
        if usage is not None and usage in self.pressed_usages:
            self.pressed_usages.remove(usage)
            self._send_state()
        return "break"


def main():
    root = tk.Tk()
    KeyGrabApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
