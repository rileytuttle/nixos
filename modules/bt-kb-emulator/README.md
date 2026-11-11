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

## Architecture

```
keygrab.py (your user, Tk GUI)  --Unix socket-->  hid_server.py (root)  --L2CAP-->  phone
   "xev-like" capture window                        pairing agent, SDP,
   keysym -> HID usage code                         raw PSM 0x11 / 0x13 sockets
```

Two processes because raw Bluetooth protocol sockets need root (or
`cap_net_raw`+`cap_net_admin`), but you don't want a keyboard-grabbing GUI
running as root on your desktop.

## Install dependencies

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
3. On your phone, open Bluetooth settings, find the PC (default alias
   "Linux Keyboard"), and pair. The server auto-confirms pairing and marks
   the phone trusted.
4. In your normal desktop session, start the capture window:
   ```
   python3 keygrab.py
   ```
5. Click the window (or press F12) to arm capture — it turns **green /
   LIVE**. Type normally; keystrokes go to the phone. Press **F12** again
   (or click away) to pause — it turns **red / PAUSED** and nothing is sent.

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
  tries to authenticate with a link key the phone has thrown away. Check
  with `bluetoothctl info <addr>` (`Paired: yes` / `Bonded: yes`) and clear
  our half with `bluetoothctl remove <addr>`. Forget on *both* sides before
  re-pairing.
- **Keystrokes go nowhere and the capture window still says LIVE**: LIVE is
  only about the window; it says nothing about whether a phone is attached.
  The line under it reports the actual link. `bt-kb-send --status` answers
  the same question without the GUI.
- **Nothing types, and you want to know which half is broken**: run
  `bt-kb-send hello`. It bypasses the GUI, X11/Wayland and the keymap
  entirely and writes straight to `hid_server.py`'s socket. If that types,
  the Bluetooth path is fine and the problem is in `keygrab.py`; if it
  doesn't, `keygrab.py` was never involved.
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
