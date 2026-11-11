#!/usr/bin/env python3
"""
HID-device-role Bluetooth keyboard server. Run as root.

Owns:
- a BlueZ pairing agent that auto-accepts pairing (NoInputNoOutput) and
  trusts the peer once bonded, so later reconnects don't need re-pairing.
- the custom SDP record for the HID service (see sdp_record.xml), registered
  via org.bluez.ProfileManager1.RegisterProfile. Modern bluetoothd's sdptool
  dropped `add --xml` (it only ever took a handful of builtin service names,
  not an arbitrary record) -- RegisterProfile's "ServiceRecord" option is the
  still-supported replacement; see BlueZ's own test/test-profile for the same
  pattern. We deliberately pass no PSM/Channel option, so bluetoothd parses
  and advertises the record but never binds a socket or calls NewConnection
  for it -- we own the data path below ourselves.
- two raw L2CAP server sockets (Control PSM 0x11, Interrupt PSM 0x13) that
  BlueZ itself does not claim -- the HID "device" data path has not been
  implemented in bluetoothd since the old standalone `hidd` was dropped, so
  we own these sockets directly.
- a local Unix domain socket that keygrab.py (running as a normal user)
  connects to, to push the live set of pressed keys.

The SDP record registration above lives only as long as this process's
D-Bus connection does, so it's re-registered every time this server starts
-- no separate one-time setup step needed.
"""
import errno
import json
import logging
import os
import socket
import stat
import sys
import threading
from xml.sax.saxutils import escape

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

# BTKB_LOG=DEBUG adds the raw interrupt-channel reports. The control-channel
# transactions are logged at INFO on purpose: they are low volume and they are
# the first thing you need when the host drops the link.
logging.basicConfig(
    level=os.environ.get("BTKB_LOG", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("hid_server")

BUS_NAME = "org.bluez"
ADAPTER_PATH = "/org/bluez/hci0"
AGENT_PATH = "/btkb/agent"
AGENT_IFACE = "org.bluez.Agent1"
AGENT_MANAGER_IFACE = "org.bluez.AgentManager1"
DEVICE_IFACE = "org.bluez.Device1"

PROFILE_PATH = "/btkb/hid_profile"
PROFILE_IFACE = "org.bluez.Profile1"
PROFILE_MANAGER_IFACE = "org.bluez.ProfileManager1"
HID_SERVICE_CLASS_UUID = "00001124-0000-1000-8000-00805f9b34fb"
SDP_RECORD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sdp_record.xml")

HID_CONTROL_PSM = 0x11
HID_INTERRUPT_PSM = 0x13
REPORT_LEN = 8  # modifier, reserved, 6 keycodes -- must match sdp_record.xml's HIDDescriptorList

# HIDP message header: high nibble is the transaction type, low nibble its
# parameter. Values from bluez profiles/input/hidp_defs.h.
HIDP_TRANS_HANDSHAKE = 0x00
HIDP_TRANS_HID_CONTROL = 0x10
HIDP_TRANS_GET_REPORT = 0x40
HIDP_TRANS_SET_REPORT = 0x50
HIDP_TRANS_GET_PROTOCOL = 0x60
HIDP_TRANS_SET_PROTOCOL = 0x70
HIDP_TRANS_GET_IDLE = 0x80
HIDP_TRANS_SET_IDLE = 0x90
HIDP_TRANS_DATA = 0xA0
HIDP_TRANS_DATC = 0xB0

TRANS_NAMES = {
    HIDP_TRANS_HANDSHAKE: "HANDSHAKE",
    HIDP_TRANS_HID_CONTROL: "HID_CONTROL",
    HIDP_TRANS_GET_REPORT: "GET_REPORT",
    HIDP_TRANS_SET_REPORT: "SET_REPORT",
    HIDP_TRANS_GET_PROTOCOL: "GET_PROTOCOL",
    HIDP_TRANS_SET_PROTOCOL: "SET_PROTOCOL",
    HIDP_TRANS_GET_IDLE: "GET_IDLE",
    HIDP_TRANS_SET_IDLE: "SET_IDLE",
    HIDP_TRANS_DATA: "DATA",
    HIDP_TRANS_DATC: "DATC",
}

HIDP_HSHK_SUCCESSFUL = 0x00
HIDP_HSHK_ERR_INVALID_REPORT_ID = 0x02
HIDP_HSHK_ERR_UNSUPPORTED_REQUEST = 0x03
HIDP_HSHK_ERR_INVALID_PARAMETER = 0x04

HIDP_CTRL_NOP = 0x00
HIDP_CTRL_HARD_RESET = 0x01
HIDP_CTRL_SOFT_RESET = 0x02
HIDP_CTRL_SUSPEND = 0x03
HIDP_CTRL_EXIT_SUSPEND = 0x04
HIDP_CTRL_VIRTUAL_CABLE_UNPLUG = 0x05

HIDP_DATA_RTYPE_MASK = 0x03
HIDP_DATA_RTYPE_OTHER = 0x00
HIDP_DATA_RTYPE_INPUT = 0x01
HIDP_DATA_RTYPE_OUTPUT = 0x02
HIDP_DATA_RTYPE_FEATURE = 0x03

HIDP_PROTO_BOOT = 0x00
HIDP_PROTO_REPORT = 0x01

# One L2CAP SEQPACKET datagram. HIDP's own minimum MTU is 48; a SET_REPORT
# carrying an output report is far smaller, but recv() on a SEQPACKET socket
# silently truncates anything longer than the buffer, so leave real headroom.
HIDP_RECV_BUF = 1024

IPC_SOCKET_PATH = os.environ.get("BTKB_IPC", "/run/btkb-hid.sock")

# What the phone shows in its Bluetooth list, and the SDP ServiceName. The
# hostname makes it obvious *which* machine you are about to let type on your
# phone, which matters once more than one of them can.
DEVICE_NAME = os.environ.get("BTKB_NAME") or f"{socket.gethostname()} keyboard"

# Addresses that have actually opened one of our HID channels, appended as
# they connect. This is what makes `bt-kb-forget` safe: it only clears bonds
# for devices recorded here, so it can never drop the pairing for headphones,
# a mouse, or anything else that merely happens to be bonded to this adapter.
# Nothing but a phone acting as an HID host ever connects to PSM 0x11/0x13.
STATE_DIR = os.environ.get("BTKB_STATE_DIR", "/var/lib/bt-kb-emulator")
PEERS_PATH = os.path.join(STATE_DIR, "peers")

# Everything this server needs from the environment -- a bluetoothd without
# the `input` plugin, root, a free PSM pair -- is static for the lifetime of
# the boot. Failing on any of it is not something a retry fixes, so exit with
# a distinct code that the systemd unit maps to RestartPreventExitStatus
# instead of spinning on Restart=on-failure forever.
EX_CONFIG = 78

INPUT_PLUGIN_HINT = (
    "bluetoothd's `input` plugin (the HID *host* role) is still loaded: it owns "
    "the HID UUID and L2CAP PSM 0x11/0x13, which the HID *device* role needs.\n"
    "Start bluetoothd with --noplugin=input and restart it:\n"
    "  NixOS: hardware.bluetooth.disabledPlugins = [ \"input\" ];\n"
    "         then `systemctl restart bluetooth` -- NixOS sets\n"
    "         restartIfChanged = false on bluetooth.service, so a\n"
    "         nixos-rebuild switch alone leaves the old bluetoothd running.\n"
    "Check with: pgrep -af bluetoothd"
)


def die_config(message):
    log.error("%s", message)
    sys.exit(EX_CONFIG)


def trust_device(bus, device_path):
    try:
        obj = bus.get_object(BUS_NAME, device_path)
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        if props.Get(DEVICE_IFACE, "Trusted"):
            return
        props.Set(DEVICE_IFACE, "Trusted", True)
        log.info("marked %s trusted", device_path)
    except dbus.exceptions.DBusException as exc:
        log.warning("could not mark %s trusted: %s", device_path, exc)


def watch_for_bonds(bus):
    """Set Trusted on any device that becomes Paired.

    Any device, not just the phone: the bond completes before anything
    connects to our HID channels, so at that point there is nothing to
    distinguish the phone by. That matches the agent above, which already
    auto-accepts every pairing in range while the server runs -- see the
    security note in README.md. It is also why bt-kb-forget keys off the
    HID-peer list rather than off Trusted.

    Doing this from the agent callbacks alone does not work. With a
    NoInputNoOutput agent and Secure Simple Pairing, a "just works" bond
    needs no user decision, so bluetoothd calls none of RequestConfirmation
    /RequestAuthorization/RequestPasskey -- it only calls AuthorizeService
    for the service connections afterwards. An iPhone paired this way came
    out `Paired: yes, Trusted: no`, i.e. the trust step silently never ran.
    The Paired property is the signal that actually always fires.
    """

    def on_properties_changed(interface, changed, _invalidated, path=None):
        if interface == DEVICE_IFACE and changed.get("Paired"):
            log.info("%s is now bonded", path)
            trust_device(bus, path)

    def on_interfaces_added(path, interfaces):
        props = interfaces.get(DEVICE_IFACE)
        if props and props.get("Paired"):
            trust_device(bus, path)

    bus.add_signal_receiver(
        on_properties_changed,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        arg0=DEVICE_IFACE,
        path_keyword="path",
    )
    bus.add_signal_receiver(
        on_interfaces_added,
        dbus_interface="org.freedesktop.DBus.ObjectManager",
        signal_name="InterfacesAdded",
    )


_peers_lock = threading.Lock()


def read_peers():
    try:
        with open(PEERS_PATH) as f:
            return [l.strip() for l in f if l.strip()]
    except FileNotFoundError:
        return []
    except OSError as exc:
        log.warning("could not read %s: %s", PEERS_PATH, exc)
        return []


def record_peer(address):
    """Note that `address` connected as an HID host. Best-effort."""
    try:
        with _peers_lock:
            if address in read_peers():
                return
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(PEERS_PATH, "a") as f:
                f.write(address + "\n")
        log.info("recorded %s as an HID peer", address)
    except OSError as exc:
        # Losing this only costs bt-kb-forget its safety list; it must never
        # take down the keystroke path.
        log.warning("could not record peer %s: %s", address, exc)


class AutoAcceptAgent(dbus.service.Object):
    """Accepts every pairing attempt. Trusting the peer is handled by
    watch_for_bonds() above, not here -- see its docstring for why these
    callbacks are not a reliable place to do it."""

    def __init__(self, bus):
        super().__init__(bus, AGENT_PATH)
        self._bus = bus

    def _trust(self, device_path):
        trust_device(self._bus, device_path)

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        log.info("agent released")

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        log.info("auto-authorizing service %s for %s", uuid, device)

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        log.info("auto pin-code for %s", device)
        self._trust(device)
        return "0000"

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        log.info("auto passkey for %s", device)
        self._trust(device)
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="")
    def DisplayPasskey(self, device, passkey):
        log.info("passkey for %s: %06d", device, passkey)

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        log.info("pin code for %s: %s", device, pincode)

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        log.info("auto-confirming pairing with %s (passkey %06d)", device, passkey)
        self._trust(device)

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        log.info("auto-authorizing %s", device)
        self._trust(device)

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self):
        log.info("pairing cancelled by peer")


class HidProfile(dbus.service.Object):
    """Minimal org.bluez.Profile1, registered purely to hold the SDP record
    below alive via ProfileManager1.RegisterProfile. We pass no PSM/Channel
    option, so bluetoothd never binds a socket or calls NewConnection on
    this -- the raw PSM 0x11/0x13 sockets below are the real data path."""

    @dbus.service.method(PROFILE_IFACE, in_signature="", out_signature="")
    def Release(self):
        log.info("HID profile released")


def setup_dbus():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    watch_for_bonds(bus)

    agent = AutoAcceptAgent(bus)
    agent_manager = dbus.Interface(bus.get_object(BUS_NAME, "/org/bluez"), AGENT_MANAGER_IFACE)
    try:
        agent_manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    except dbus.exceptions.DBusException as exc:
        if exc.get_dbus_name() != "org.bluez.Error.AlreadyExists":
            raise
        die_config(
            f"an agent is already registered at {AGENT_PATH} -- another copy of "
            "this server is still running. Check with: pgrep -af hid_server.py"
        )
    agent_manager.RequestDefaultAgent(AGENT_PATH)
    log.info("pairing agent registered")

    profile = HidProfile(bus, PROFILE_PATH)
    profile_manager = dbus.Interface(bus.get_object(BUS_NAME, "/org/bluez"), PROFILE_MANAGER_IFACE)
    with open(SDP_RECORD_PATH) as f:
        sdp_record_xml = f.read()
    # escape(): the name comes from the hostname or $BTKB_NAME, and this is
    # being spliced into an XML attribute that bluetoothd then parses.
    sdp_record_xml = sdp_record_xml.replace("@DEVICE_NAME@", escape(DEVICE_NAME, {'"': "&quot;"}))
    # Role=server: without it bluetoothd defaults a profile to both roles
    # and would also probe every paired device as an HID *client*, trying to
    # connect outbound to the phone's (nonexistent) HID service. We pass no
    # PSM/Channel, so ext_start_servers() binds nothing and goes straight to
    # registering our ServiceRecord -- the raw sockets below are the data path.
    try:
        profile_manager.RegisterProfile(
            PROFILE_PATH,
            HID_SERVICE_CLASS_UUID,
            {
                "ServiceRecord": sdp_record_xml,
                "Role": "server",
                "RequireAuthentication": dbus.Boolean(False),
                "RequireAuthorization": dbus.Boolean(False),
            },
        )
    except dbus.exceptions.DBusException as exc:
        # register_profile() in src/profile.c rejects a UUID that any other
        # btd_profile already claims, and profiles/input/manager.c claims
        # HID_UUID. So this is the same root cause as an EADDRINUSE on the
        # PSMs below, just caught earlier and with a less obvious message.
        if "already registered" not in str(exc):
            raise
        die_config(f"bluetoothd refused the HID profile ({exc.get_dbus_message()}).\n{INPUT_PLUGIN_HINT}")
    log.info("HID SDP record registered")

    adapter_props = dbus.Interface(bus.get_object(BUS_NAME, ADAPTER_PATH), "org.freedesktop.DBus.Properties")
    # Powered first: Discoverable/Pairable are silently useless on a
    # rfkill'd or soft-blocked adapter, and the Set() calls below succeed
    # anyway, so without this the server looks healthy but is invisible.
    adapter_props.Set("org.bluez.Adapter1", "Powered", True)
    adapter_props.Set("org.bluez.Adapter1", "Alias", DEVICE_NAME)
    adapter_props.Set("org.bluez.Adapter1", "Discoverable", True)
    adapter_props.Set("org.bluez.Adapter1", "DiscoverableTimeout", dbus.UInt32(0))
    adapter_props.Set("org.bluez.Adapter1", "Pairable", True)
    log.info("adapter is now discoverable/pairable as %r", DEVICE_NAME)

    loop = GLib.MainLoop()
    threading.Thread(target=loop.run, daemon=True, name="dbus-mainloop").start()


class HidLink:
    """Tracks the currently-connected phone's interrupt channel, plus the
    small amount of HID state the host can ask us about over the control
    channel (protocol mode, idle rate, last input report, LED state)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._interrupt_conn = None
        self._last_report = bytes(REPORT_LEN)
        # Report protocol is the post-boot default per the HID spec; the host
        # tells us otherwise with SET_PROTOCOL. For this keyboard the two are
        # identical anyway -- the descriptor has no report IDs, so the boot
        # and report protocol both carry the same 8-byte layout.
        self._protocol = HIDP_PROTO_REPORT
        self._idle_rate = 0
        self._led_state = 0
        self._watchers = []  # IPC sockets wanting link up/down notifications

    # -- link state ---------------------------------------------------------
    def set_interrupt(self, conn):
        with self._lock:
            self._interrupt_conn = conn
        self._notify_watchers()

    def clear_interrupt(self, conn):
        with self._lock:
            if self._interrupt_conn is not conn:
                return
            self._interrupt_conn = None
            self._last_report = bytes(REPORT_LEN)
        self._notify_watchers()

    def connected(self):
        with self._lock:
            return self._interrupt_conn is not None

    # -- state the control channel can query --------------------------------
    @property
    def protocol(self):
        with self._lock:
            return self._protocol

    @protocol.setter
    def protocol(self, value):
        with self._lock:
            self._protocol = value

    @property
    def idle_rate(self):
        with self._lock:
            return self._idle_rate

    @idle_rate.setter
    def idle_rate(self, value):
        with self._lock:
            self._idle_rate = value

    @property
    def led_state(self):
        with self._lock:
            return self._led_state

    @led_state.setter
    def led_state(self, value):
        with self._lock:
            self._led_state = value

    def last_report(self):
        with self._lock:
            return self._last_report

    # -- keystroke path -----------------------------------------------------
    def send_report(self, modifiers: int, keys: list):
        report = bytes([modifiers, 0]) + bytes((keys + [0, 0, 0, 0, 0, 0])[:6])
        assert len(report) == REPORT_LEN
        packet = bytes([HIDP_TRANS_DATA | HIDP_DATA_RTYPE_INPUT]) + report
        with self._lock:
            conn = self._interrupt_conn
            self._last_report = report
        if conn is None:
            # The usual cause of "I type and nothing happens": the phone
            # never connected, or dropped the link. Say so rather than
            # discarding the report in silence.
            log.warning("no interrupt channel -- dropping report %s", report.hex())
            return False
        try:
            conn.send(packet)
            log.debug("interrupt -> %s", packet.hex())
            return True
        except OSError as exc:
            log.warning("send failed, dropping interrupt connection: %s", exc)
            self.clear_interrupt(conn)
            return False

    # -- IPC status fan-out -------------------------------------------------
    def add_watcher(self, conn):
        with self._lock:
            self._watchers.append(conn)
        self.send_status(conn)

    def remove_watcher(self, conn):
        with self._lock:
            if conn in self._watchers:
                self._watchers.remove(conn)

    def send_status(self, conn):
        line = (json.dumps({"link": self.connected()}) + "\n").encode()
        try:
            conn.sendall(line)
        except OSError:
            self.remove_watcher(conn)

    def _notify_watchers(self):
        with self._lock:
            watchers = list(self._watchers)
        for conn in watchers:
            self.send_status(conn)


def l2cap_listener(psm):
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    try:
        sock.bind((socket.BDADDR_ANY, psm))
    except OSError as exc:
        sock.close()
        if exc.errno == errno.EADDRINUSE:
            die_config(f"PSM 0x{psm:02x} is already bound.\n{INPUT_PLUGIN_HINT}")
        if exc.errno == errno.EACCES:
            die_config(
                f"not allowed to bind PSM 0x{psm:02x}: a PSM below 0x1000 needs "
                "CAP_NET_BIND_SERVICE (and the raw socket needs CAP_NET_RAW). "
                "Run as root."
            )
        die_config(f"could not bind PSM 0x{psm:02x}: {exc}")
    sock.listen(1)
    return sock


def control_accept_loop(sock, link: HidLink):
    while True:
        conn, addr = sock.accept()
        log.info("control channel connected from %s", addr)
        record_peer(addr[0])
        threading.Thread(target=_control_read_loop, args=(conn, addr, link), daemon=True).start()


def _control_read_loop(conn, addr, link: HidLink):
    """Answer the host's HIDP control-channel transactions.

    This is not optional housekeeping. Every request here demands a reply --
    a HANDSHAKE, or a DATA for the GET_* ones -- and a host that doesn't get
    one tears the whole link down after a few seconds. Ignoring the control
    channel looks exactly like "the phone pairs and then immediately
    disconnects", with no error anywhere on our side.
    """
    try:
        while True:
            data = conn.recv(HIDP_RECV_BUF)
            if not data:
                break
            if not _handle_control(conn, addr, data, link):
                break
    except OSError as exc:
        log.info("control channel error for %s: %s", addr, exc)
    finally:
        log.info("control channel closed for %s", addr)
        conn.close()


def _handle_control(conn, addr, data, link: HidLink):
    """Handle one control-channel transaction. False means close the link."""
    header = data[0]
    trans = header & 0xF0
    param = header & 0x0F
    log.info(
        "control <- %s %s(param=0x%x) %s",
        addr[0], TRANS_NAMES.get(trans, f"0x{trans:02x}"), param, data.hex(),
    )

    def send(payload):
        log.info("control -> %s %s", addr[0], payload.hex())
        conn.send(payload)

    def handshake(code):
        send(bytes([HIDP_TRANS_HANDSHAKE | code]))

    if trans == HIDP_TRANS_SET_PROTOCOL:
        # param bit 0: 1 = Report protocol, 0 = Boot protocol.
        link.protocol = param & 0x01
        log.info(
            "host selected %s protocol",
            "report" if link.protocol == HIDP_PROTO_REPORT else "boot",
        )
        handshake(HIDP_HSHK_SUCCESSFUL)

    elif trans == HIDP_TRANS_GET_PROTOCOL:
        send(bytes([HIDP_TRANS_DATA | HIDP_DATA_RTYPE_OTHER, link.protocol]))

    elif trans == HIDP_TRANS_GET_REPORT:
        rtype = param & HIDP_DATA_RTYPE_MASK
        if rtype == HIDP_DATA_RTYPE_INPUT:
            send(bytes([HIDP_TRANS_DATA | HIDP_DATA_RTYPE_INPUT]) + link.last_report())
        elif rtype == HIDP_DATA_RTYPE_OUTPUT:
            send(bytes([HIDP_TRANS_DATA | HIDP_DATA_RTYPE_OUTPUT, link.led_state]))
        else:
            handshake(HIDP_HSHK_ERR_UNSUPPORTED_REQUEST)

    elif trans == HIDP_TRANS_SET_REPORT:
        rtype = param & HIDP_DATA_RTYPE_MASK
        if rtype == HIDP_DATA_RTYPE_OUTPUT and len(data) >= 2:
            # The keyboard LED bitmap (caps lock etc). We have no LEDs to
            # light, but the host still requires the acknowledgement.
            link.led_state = data[1]
            log.info("host set LED state to 0x%02x", link.led_state)
            handshake(HIDP_HSHK_SUCCESSFUL)
        else:
            handshake(HIDP_HSHK_ERR_UNSUPPORTED_REQUEST)

    elif trans == HIDP_TRANS_GET_IDLE:
        send(bytes([HIDP_TRANS_DATA | HIDP_DATA_RTYPE_OTHER, link.idle_rate]))

    elif trans == HIDP_TRANS_SET_IDLE:
        link.idle_rate = data[1] if len(data) >= 2 else 0
        handshake(HIDP_HSHK_SUCCESSFUL)

    elif trans == HIDP_TRANS_HID_CONTROL:
        # HID_CONTROL is the one request that takes no handshake.
        if param == HIDP_CTRL_VIRTUAL_CABLE_UNPLUG:
            log.info("host unplugged the virtual cable -- closing link")
            return False
        log.info("host sent HID_CONTROL param 0x%x (ignored)", param)

    elif trans in (HIDP_TRANS_DATA, HIDP_TRANS_DATC):
        # An output report pushed at us rather than via SET_REPORT. No reply.
        if (param & HIDP_DATA_RTYPE_MASK) == HIDP_DATA_RTYPE_OUTPUT and len(data) >= 2:
            link.led_state = data[1]
            log.info("host pushed LED state 0x%02x", link.led_state)

    elif trans == HIDP_TRANS_HANDSHAKE:
        log.info("host handshake, code 0x%x", param)

    else:
        log.warning("unknown HIDP transaction 0x%02x -- replying unsupported", trans)
        handshake(HIDP_HSHK_ERR_UNSUPPORTED_REQUEST)

    return True


def interrupt_accept_loop(sock, link: HidLink):
    while True:
        conn, addr = sock.accept()
        log.info("interrupt channel connected from %s -- phone is ready for keystrokes", addr)
        record_peer(addr[0])
        link.set_interrupt(conn)
        threading.Thread(target=_interrupt_read_loop, args=(conn, addr, link), daemon=True).start()


def _interrupt_read_loop(conn, addr, link: HidLink):
    try:
        while True:
            data = conn.recv(HIDP_RECV_BUF)
            if not data:
                break
            # Output reports (the LED bitmap) may arrive here instead of on
            # the control channel. Nothing on the interrupt channel is
            # acknowledged, so this is log-and-record only.
            header = data[0]
            if (header & 0xF0) == HIDP_TRANS_DATA and \
                    (header & HIDP_DATA_RTYPE_MASK) == HIDP_DATA_RTYPE_OUTPUT and len(data) >= 2:
                link.led_state = data[1]
                log.info("interrupt <- %s LED state 0x%02x", addr[0], link.led_state)
            else:
                log.info("interrupt <- %s %s", addr[0], data.hex())
    except OSError as exc:
        log.info("interrupt channel error for %s: %s", addr, exc)
    finally:
        log.info("interrupt channel closed for %s", addr)
        link.clear_interrupt(conn)
        conn.close()


def ipc_server_loop(link: HidLink):
    try:
        os.unlink(IPC_SOCKET_PATH)
    except FileNotFoundError:
        pass

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(IPC_SOCKET_PATH)
    os.chmod(IPC_SOCKET_PATH, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IWGRP | stat.S_IROTH | stat.S_IWOTH)
    sock.listen(4)
    log.info("IPC socket listening at %s", IPC_SOCKET_PATH)

    while True:
        conn, _ = sock.accept()
        threading.Thread(target=_ipc_client_loop, args=(conn, link), daemon=True).start()


def _ipc_client_loop(conn, link: HidLink):
    log.info("keygrab client connected")
    # The client gets the current link state immediately and an update on
    # every change, so it can show whether a phone is actually listening
    # instead of cheerfully reporting LIVE into a closed socket.
    link.add_watcher(conn)
    buf = b""
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError as exc:
                    log.warning("bad IPC message %r: %s", line, exc)
                    continue
                if "keys" in msg:
                    try:
                        link.send_report(int(msg["mods"]), list(msg["keys"]))
                    except (KeyError, TypeError, ValueError) as exc:
                        log.warning("bad IPC report %r: %s", line, exc)
                elif msg.get("op") == "status":
                    link.send_status(conn)
                else:
                    log.warning("unknown IPC message %r", line)
    except OSError:
        pass
    finally:
        link.remove_watcher(conn)
        log.info("keygrab client disconnected")
        conn.close()


def main():
    if os.geteuid() != 0:
        die_config("hid_server.py must run as root (raw L2CAP sockets need it)")

    setup_dbus()

    link = HidLink()
    control_sock = l2cap_listener(HID_CONTROL_PSM)
    interrupt_sock = l2cap_listener(HID_INTERRUPT_PSM)

    threading.Thread(target=control_accept_loop, args=(control_sock, link), daemon=True, name="control-accept").start()
    threading.Thread(target=interrupt_accept_loop, args=(interrupt_sock, link), daemon=True, name="interrupt-accept").start()

    log.info("ready -- pair your phone with %r now", DEVICE_NAME)
    ipc_server_loop(link)  # blocks forever


if __name__ == "__main__":
    main()
