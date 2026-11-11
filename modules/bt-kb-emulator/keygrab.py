#!/usr/bin/env python3
"""
xev-like capture window. Run as your normal desktop user (no root needed).

While armed (green/LIVE), every key press/release in this window is
translated to a USB HID usage code and streamed to hid_server.py over a
Unix socket, which forwards it to the paired phone as a Bluetooth keyboard
report.

F12 toggles armed/paused and is never itself forwarded -- it's intercepted
before reaching the keymap, since Escape (a key you DO want to send to the
phone) can't double as the "stop capturing" sequence. F11 pastes the host
clipboard to the phone and is intercepted the same way.

Losing focus auto-pauses and releases any held keys, so alt-tabbing away
mid-keypress can't leave a key stuck down on the phone -- and regaining
focus re-arms, so alt-tab away and back is round-trip neutral. An explicit
F12 pause is remembered: it stays paused until you explicitly unpause.
"""
import json
import os
import socket
import tkinter as tk

from btkb_clip import ClipboardError, read_clipboard
from hid_keymap import MODIFIER_MASK, reports_for_text, usage_for_keysym

IPC_SOCKET_PATH = os.environ.get("BTKB_IPC", "/run/btkb-hid.sock")

# Gap between the press and release reports of a pasted character. Fast
# enough not to feel slow, slow enough that phones don't drop characters.
PASTE_INTERVAL_MS = 8


class KeyGrabApp:
    def __init__(self, root):
        self.root = root
        self.armed = False
        # Distinguishes "paused because you alt-tabbed away" from "paused
        # because you pressed F12". Only the former auto-resumes on refocus;
        # an explicit pause has to be explicitly undone, or the window would
        # start sending again the moment you clicked back into it.
        self.auto_paused = False
        self.paste_queue = []
        self.modifier_byte = 0
        self.pressed_usages = []  # ordered, HID boot protocol supports up to 6
        self.sock = None
        self._rxbuf = b""

        root.title("bt-kb-emulator")
        root.geometry("480x320")

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

        self.paste_button = tk.Button(
            root, text="Paste clipboard (F11)", command=self.paste_clipboard,
            highlightthickness=0,
        )
        # takefocus=0: the button must never steal focus from the toplevel,
        # or clicking it would fire <FocusOut> and pause the capture.
        self.paste_button.config(takefocus=0)
        self.paste_button.pack(pady=4)

        hint = tk.Label(
            root,
            text="F12 or click the status bar to arm/pause. F11 pastes the clipboard.\n"
                 "Losing focus auto-pauses; regaining it resumes.",
            font=("sans-serif", 10),
            fg="#666666",
        )
        hint.pack(fill="x", pady=6)

        root.bind("<KeyPress>", self.on_key_press)
        root.bind("<KeyRelease>", self.on_key_release)
        root.bind("<FocusOut>", self.on_focus_out)
        root.bind("<FocusIn>", self.on_focus_in)

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
        self._send_report(self.modifier_byte, self.pressed_usages[:6])

    def _send_report(self, mods, keys):
        if self.sock is None:
            self._connect_ipc()
            if self.sock is None:
                return
        msg = json.dumps({"mods": mods, "keys": list(keys)[:6]}) + "\n"
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
        elif self.auto_paused:
            self.status.config(text="PAUSED (no focus)", bg="#ef6c00", fg="white")
        else:
            self.status.config(text="PAUSED", bg="#c62828", fg="white")

    def toggle_armed(self):
        self.armed = not self.armed
        # An explicit toggle overrides an auto-pause in both directions: it
        # either resumes now, or means "stay paused even when I come back".
        self.auto_paused = False
        if not self.armed:
            self._release_all()
        self._render_state()

    def _release_all(self):
        self.modifier_byte = 0
        self.pressed_usages = []
        self._send_state()

    def on_focus_out(self, event):
        # Tk also reports focus moving between this window's own widgets;
        # only a change on the toplevel means the window itself lost focus.
        if event.widget is not self.root:
            return
        if self.armed:
            self.armed = False
            self.auto_paused = True
            self._release_all()
            self._render_state()

    def on_focus_in(self, event):
        if event.widget is not self.root:
            return
        if self.auto_paused:
            self.armed = True
            self.auto_paused = False
            self._render_state()

    def paste_clipboard(self):
        if self.sock is None:
            self.lastkey.config(text="paste: not connected to hid_server")
            return
        if not self.linked:
            self.lastkey.config(text="paste: no phone connected")
            return
        try:
            text = read_clipboard(self.root)
        except ClipboardError as exc:
            self.lastkey.config(text=f"paste failed: {exc}")
            return
        # \r\n and lone \r both mean Return; without this a copied Windows
        # or classic-Mac line ending types a stray second newline or none.
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        if not text:
            self.lastkey.config(text="paste: clipboard is empty")
            return

        reports, skipped = reports_for_text(text)
        self.paste_queue = reports
        note = f"pasting {len(text)} chars"
        if skipped:
            note += f" (skipping {''.join(sorted(skipped))})"
        self.lastkey.config(text=note)
        self._drain_paste_queue()

    def _drain_paste_queue(self):
        """Send one queued report per Tk tick.

        Not a loop with sleep(): that would block the mainloop, freezing the
        window for the length of the paste and leaving no way to see progress
        or stop it. One report per tick also paces the stream -- a phone that
        gets 8-byte reports back to back faster than it polls will drop
        characters.
        """
        if not self.paste_queue:
            # Restore whatever is physically held now, so a paste can't leave
            # the phone's idea of the keyboard out of sync with this window's.
            self._send_state()
            self.paste_button.config(state="normal")
            return
        self.paste_button.config(state="disabled")
        mods, keys = self.paste_queue.pop(0)
        self._send_report(mods, keys)
        self.root.after(PASTE_INTERVAL_MS, self._drain_paste_queue)

    def on_key_press(self, event):
        if event.keysym == "F12":
            self.toggle_armed()
            return "break"

        if event.keysym == "F11":
            # Intercepted locally like F12, so F11 is never forwarded. Works
            # whether or not capture is armed -- a paste is an explicit act.
            self.paste_clipboard()
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
