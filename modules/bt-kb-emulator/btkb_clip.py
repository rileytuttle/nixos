"""
Read the host clipboard as text.

Tried in order, because none of them works everywhere:

- wl-paste, for a Wayland session (niri, sway, GNOME...). The authoritative
  source there; XWayland's clipboard is a bridged copy that can lag or be
  missing entirely for clients that never touched X11.
- xclip / xsel, for a real X11 session.
- Tk's own clipboard_get(), which goes through XWayland under Wayland. Last
  because of the above, but it needs no external binary, so it is the only
  one that works in a stripped-down environment.
"""
import os
import shutil
import subprocess


class ClipboardError(Exception):
    pass


def _run(argv):
    try:
        proc = subprocess.run(argv, capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ClipboardError(f"{argv[0]}: {exc}") from exc
    if proc.returncode != 0:
        err = proc.stderr.decode(errors="replace").strip()
        raise ClipboardError(f"{argv[0]} exited {proc.returncode}: {err}")
    return proc.stdout.decode(errors="replace")


def read_clipboard(tk_widget=None):
    """Clipboard text, or raise ClipboardError naming everything that failed."""
    attempts = []

    if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-paste"):
        # -n: don't add the trailing newline wl-paste normally appends, which
        # would otherwise press Return at the end of every paste.
        try:
            return _run(["wl-paste", "--no-newline", "--type", "text/plain;charset=utf-8"])
        except ClipboardError as exc:
            attempts.append(str(exc))
            try:
                return _run(["wl-paste", "--no-newline"])
            except ClipboardError as exc2:
                attempts.append(str(exc2))

    for tool in (["xclip", "-selection", "clipboard", "-o"], ["xsel", "--clipboard", "--output"]):
        if shutil.which(tool[0]):
            try:
                return _run(tool)
            except ClipboardError as exc:
                attempts.append(str(exc))

    if tk_widget is not None:
        try:
            return tk_widget.clipboard_get()
        except Exception as exc:  # tkinter.TclError for an empty/non-text selection
            attempts.append(f"tk clipboard_get: {exc}")

    if not attempts:
        attempts.append("no clipboard tool found (install wl-clipboard or xclip)")
    raise ClipboardError("; ".join(attempts))
