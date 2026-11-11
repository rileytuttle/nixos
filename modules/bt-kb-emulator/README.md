# bt-kb-emulator

Turns your Linux PC into a Bluetooth keyboard *peripheral* (the "HID Device"
role) — the HID analogue of how BlueZ lets a PC act as an A2DP *sink*
("pretend to be a speaker"). Pair your phone to the PC, and while a capture
window is armed, your PC's physical keystrokes are sent to the phone as
Bluetooth keyboard input.

BlueZ does not implement the HID *device* data path itself (that role was
dropped from `bluetoothd` along with the old `hidd` tool years ago) — it only
handles pairing/bonding and SDP advertisement. The actual keystroke traffic is
two raw L2CAP sockets we own directly:

- **Control channel**, PSM `0x11` — housekeeping (SET_PROTOCOL etc.), mostly ignored here.
- **Interrupt channel**, PSM `0x13` — this is where 8-byte boot-protocol keyboard reports go.

## Commands

Everything this module installs, so there is nothing to go hunting for:

| command | what it does | root? |
|---|---|---|
| `bt-kb-keygrab` | the capture window. F12 arms/pauses, F11 pastes the clipboard. | no |
| `bt-kb-send` | type without the GUI: `bt-kb-send hello`, `--clipboard`, `--stdin`, `--status`. | no |
| `bt-kb-forget` | clear this machine's half of a stale bond when the phone refuses to re-pair. `--list`, `--restart`. | yes (it sudos) |
| `bt-kb-setup` | non-NixOS only: install the system units. `--status`, `--uninstall`. | yes (it sudos) |
| `bt-kb-hid-server` | the server. Normally run via `systemctl start bt-kb-hid-server`, not by hand. | yes |

The server is deliberately not started at boot, and `nixos-rebuild switch`
deliberately does not restart it — see `module.nix`.

## Architecture

```
keygrab.py (your user, Tk GUI)  --Unix socket-->  hid_server.py (root)  --L2CAP-->  phone
   "xev-like" capture window                        pairing agent, SDP,
   keysym -> HID usage code                         HIDP control channel,
                                                    raw PSM 0x11 / 0x13 sockets
btkb_send.py (same socket, no GUI)  ----------------^
   bt-kb-send: type text, paste the clipboard, or just ask whether a
   phone is connected. The way to tell a broken Bluetooth link apart
   from a broken capture window.
```

Two processes because raw Bluetooth protocol sockets need root (or
`cap_net_raw`+`cap_net_admin`), but you don't want a keyboard-grabbing GUI
running as root on your desktop.

## Installing

Two nix routes, depending on the host:

- **NixOS**: `imports = [ .../bt-kb-emulator/module.nix ];`. Declares the
  system service, `--noplugin=input` and the Class of Device. Nothing
  imperative to run; see the prerequisite note below about restarting
  `bluetooth.service` the first time.
- **nix + home-manager on another distro** (Ubuntu, Fedora, Arch):
  `imports = [ .../bt-kb-emulator/home.nix ];`, then run `bt-kb-setup` once.

`home.nix` can only install the user-facing half. The server needs raw
`AF_BLUETOOTH` L2CAP sockets, so it needs real root and cannot live in
`systemd --user`, and the `input` plugin has to be disabled in the system
`bluetooth.service`. Both are root-owned system state. `bt-kb-setup` sudos
and writes exactly two files, both marked as its own:

- `/etc/systemd/system/bt-kb-hid-server.service`
- `/etc/systemd/system/bluetooth.service.d/90-bt-kb-emulator.conf`

It never edits a file the distro owns, so `bt-kb-setup --uninstall` is exact
— deleting the drop-in restores the packaged `bluetoothd` command line. If an
existing `--noplugin=` is already there, ours is merged into it rather than
appended, since a second `--noplugin=` would override the first and silently
re-enable whatever the distro disabled. `bt-kb-setup --status` shows what is
installed and running.

The unit pins a `/nix/store` path, so **re-run `bt-kb-setup` after a
home-manager update** that changes this package; `--status` says so when the
installed unit has drifted. On NixOS `bt-kb-setup` refuses to run, so the two
routes can't fight.

## Install dependencies (without nix)

Debian/Ubuntu:
```
sudo apt install bluez bluez-tools python3-dbus python3-gi python3-tk
```
Arch:
```
sudo pacman -S bluez bluez-utils python-dbus python-gobject tk
```
Fedora:
```
sudo dnf install bluez bluez-tools python3-dbus python3-gobject python3-tkinter
```

`bluez-tools`/`bluez-utils` should give you `sdptool`. If your distro no
longer ships it, see "Troubleshooting" below.

## Prerequisite: free up PSM 0x11/0x13

This is mandatory, not a troubleshooting step. `bluetoothd`'s `input` plugin
is the HID *host* role (your PC driving an external Bluetooth keyboard or
mouse), and `server_probe()` in `profiles/input/server.c` binds L2CAP PSM
0x11 and 0x13 on every adapter as soon as the plugin loads. Those are the
exact two PSMs the HID *device* role needs, so `hid_server.py` cannot have
them while the plugin is loaded. Binding `BDADDR_ANY` alongside it doesn't
help either: the kernel's `l2cap_global_chan_by_psm()` prefers a channel
whose source address matches the adapter exactly over a `BDADDR_ANY`
wildcard, so `bluetoothd` would quietly swallow every connection from the
phone instead of erroring out.

Start `bluetoothd` with `--noplugin=input` and restart it:

```
bluetoothd --noplugin=input      # add the flag in your bluetooth.service
systemctl restart bluetooth
```

On NixOS the `module.nix` here does this for you via
`hardware.bluetooth.disabledPlugins = [ "input" ]`. Note that NixOS sets
`restartIfChanged = false` on `bluetooth.service`, so a `nixos-rebuild switch`
will *not* pick up the new flag -- restart it by hand once.

Older tutorials say to put `DisablePlugins = input` in
`/etc/bluetooth/main.conf`. That is not a `main.conf` key in BlueZ 5.x and is
silently ignored (see the accepted-key list in `src/main.c`). Only the
`-P`/`--noplugin` command line flag works.

**The cost:** while the `input` plugin is disabled this machine cannot act as
a Bluetooth HID host, i.e. no external Bluetooth keyboards or mice. Audio,
networking and the rest of BlueZ are unaffected.

## Running

1. Make sure `bluetoothd` is running with `--noplugin=input` (above).
2. Start the HID server as root:
   ```
   sudo python3 hid_server.py
   ```
   This powers on the adapter, makes it discoverable/pairable, runs an
   auto-accept pairing agent, registers the SDP record over D-Bus
   (`org.bluez.ProfileManager1.RegisterProfile`, with `sdp_record.xml` as the
   `ServiceRecord` option and `Role=server`), and opens the control/interrupt
   sockets. No separate `sdptool` step: modern `sdptool add` only takes a
   handful of builtin service names, not an arbitrary record, so `add --xml`
   doesn't work with current BlueZ regardless of distro.

   Nor is there a `btmgmt class` step any more. The Class of Device (major
   0x05 Peripheral, minor 0x40 keyboard, i.e. `0x000540`) is a real
   `main.conf` key: `Class = 0x000540` under `[General]`. It is more than
   cosmetic -- some phones filter scan results by device class.
3. On your phone, open Bluetooth settings, find the PC and pair. The server
   auto-confirms pairing and marks the phone trusted.

   The name is `<hostname> keyboard` (so "fw12 keyboard"), set as both the
   adapter alias and the SDP ServiceName — it matters which machine you are
   about to let type on your phone. Override with `$BTKB_NAME`.
4. In your normal desktop session, start the capture window:
   ```
   python3 keygrab.py
   ```
5. Click the window (or press F12) to arm capture — it turns **green /
   LIVE**. Type normally; keystrokes go to the phone. Press **F12** again
   (or click away) to pause — it turns **red / PAUSED** and nothing is sent.

### Pasting

**F11**, or the button, types the host clipboard to the phone. `wl-paste` is
tried first on Wayland (XWayland's clipboard is a bridged copy that can lag
or be missing), then `xclip`/`xsel`, then Tk's own clipboard as a
no-dependencies fallback. Characters the US keymap has no key for are
skipped and named, rather than silently dropped.

Pasting sends one report per Tk tick instead of blocking in a loop: the
window stays responsive, and a phone that gets 8-byte reports faster than it
polls drops characters.

Without the GUI: `bt-kb-send --clipboard`, or `cmd | bt-kb-send --stdin`.

### Arming, pausing, and focus

Losing focus auto-pauses and releases held keys, so alt-tabbing away
mid-keypress can't leave a key stuck down on the phone. **Regaining focus
re-arms**, so alt-tab away and back is round-trip neutral.

An explicit F12 pause is remembered and does *not* auto-resume — otherwise
the window would start sending again the moment you clicked back into it.
The status bar distinguishes the two: `PAUSED (no focus)` vs `PAUSED`.

### Why F12 and not Escape?

Escape is a real key you'll want to send *to* the phone, so it can't double
as the "stop capturing" sequence. F12 is intercepted locally before it ever
reaches the key-mapping logic, so it's never forwarded — it only toggles
capture on/off. Losing window focus (alt-tab away, click elsewhere) also
auto-pauses and releases any held keys, so nothing gets stuck down on the
phone if you walk away mid-keypress.

## Troubleshooting

- **`hid_server.py` fails with "Address already in use" binding PSM 0x11/0x13**:
  the `input` plugin is still loaded -- see "Prerequisite" above. The server
  prints that hint itself on `EADDRINUSE`.
- **`hid_server.py` fails with "Permission denied" binding PSM 0x11/0x13**:
  you are not root. An L2CAP PSM below 0x1000 needs `CAP_NET_BIND_SERVICE`,
  and the raw socket itself needs `CAP_NET_RAW`.
- **Phone never sees "Linux Keyboard" at all**: check `bluetoothctl show` for
  `Powered: yes`, `Discoverable: yes` and `Class: 0x000540`. A class of
  `0x000000` means `main.conf` wasn't picked up.
- **Phone pairs, connects, then drops the link after a few seconds**: the
  host's HIDP control-channel requests aren't being answered. Every
  `SET_PROTOCOL`/`GET_REPORT`/`SET_REPORT`/`*_IDLE` transaction demands a
  reply (a `HANDSHAKE`, or a `DATA` for the `GET_*` ones), and a host that
  doesn't get one tears the connection down on a timeout with no error on
  our side. `hid_server.py` handles these; the journal logs every control
  transaction and our reply at INFO, so `journalctl -u bt-kb-hid-server -f`
  shows exactly what was asked and what we said.
- **"You need to forget this device first" when re-pairing**: the bond is
  half-gone — removed on the phone but still present on the PC, which then
  tries to authenticate with a link key the phone has thrown away. Nothing
  on either side reports this; it reads as the phone being stubborn. Fix:
  ```
  bt-kb-forget --list       # confirm: Paired, Bonded on our side
  bt-kb-forget --restart    # clear our half and restart the server
  ```
  then forget it on the phone too and pair fresh. `bluetoothctl info <addr>`
  and `bluetoothctl remove <addr>` do the same thing by hand.

  `bt-kb-forget` only touches addresses `hid_server.py` recorded as having
  opened one of our HID channels (kept in `/var/lib/bt-kb-emulator/peers`).
  Headphones, mice and controllers never connect to PSM 0x11/0x13, so they
  can never be caught by it — `--list` shows them explicitly as left alone,
  and a non-peer address needs `--force`. The list fills in the first time a
  phone connects, so right after a fresh install there is nothing to clear
  and you need `--force <addr>`.

  If nothing has been recorded yet, it falls back to bonded devices whose
  Class of Device says *phone* (major class 0x02), so a first run needs no
  `--force`. Headphones are 0x04 and mice 0x05, so that fallback can't reach
  them either; `--list` shows exactly which device it would act on.

  **Why this is not wired into `nixos-rebuild`.** It shouldn't need to be —
  the reason it kept recurring was the rebuild itself. A switch restarted
  `bt-kb-hid-server`, which closes the L2CAP sockets under a connected
  phone; the phone drops off, the natural reaction is to forget it there,
  and that is precisely what creates the half-bond. So the module now sets
  `restartIfChanged = false` (and `stopIfChanged = false`): a rebuild leaves
  the running server alone, and you pick up a new build when you choose to,
  with `sudo systemctl restart bt-kb-hid-server`. The device name is derived
  from the hostname now too, so it no longer changes between builds and the
  phone stops showing stale entries.

  Clearing on every switch would have been the wrong fix regardless: most
  rebuilds have nothing to do with this module, so it would cost a re-pair
  after every unrelated system update — and clearing *unscoped* would drop
  your headphones and mouse too.
- **Keystrokes go nowhere and the capture window still says LIVE**: LIVE is
  only about the window; it says nothing about whether a phone is attached.
  The line under it reports the actual link. `bt-kb-send --status` answers
  the same question without the GUI.
- **Nothing types, and you want to know which half is broken**: run
  `bt-kb-send hello`. It bypasses the GUI, X11/Wayland and the keymap
  entirely and writes straight to `hid_server.py`'s socket. If that types,
  the Bluetooth path is fine and the problem is in `keygrab.py`; if it
  doesn't, `keygrab.py` was never involved.
- **Letters work but punctuation does nothing at all**: a Tk version skew.
  `event.keysym` for printable punctuation is the X keysym *name*
  ("period", "exclam") on Tk 8.6 but the bare character (".", "!") on Tk
  9.0. Letters hide it — "a" is both — so a name-keyed table matches every
  letter and no punctuation, and unmapped keys are dropped silently rather
  than erroring. `usage_for_keysym()` accepts both spellings. Check your Tk
  with `python3 -c 'import tkinter; print(tkinter.TkVersion)'`.
- **No keyboard LEDs**: the caps-lock light and friends are not implemented
  — an intentional simplification. The server does acknowledge the host's
  LED `SET_REPORT` (required, or the host drops the link) and remembers the
  bitmap; it just has nothing to light up.
- **Security note**: the auto-accept pairing agent (`NoInputNoOutput`,
  always-confirm) is convenient but means *anything* in Bluetooth range can
  pair while discoverable. Only run `hid_server.py` while you're actively
  pairing, or tighten the agent before leaving it running unattended. Also,
  the local Unix socket that `keygrab.py` uses to reach `hid_server.py` is
  world-writable (`0666`) so the GUI doesn't need root — any local user on
  the machine can inject keystrokes to the connected phone. Fine for a
  personal single-user machine; not something to run on a shared box.
