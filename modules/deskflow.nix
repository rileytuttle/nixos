# system config module (e.g. modules/deskflow.nix), imported per-host
{ config, lib, pkgs, ... }:

let
  # Not an overlay: nothing else in the tree needs it, same as
  # modules/bt-kb-emulator. Pinned against this pkgs.deskflow on purpose --
  # see the comment on NKCF_DESKFLOW_EXECUTABLE in the package.
  niri-kdeconnect-portal = pkgs.callPackage ../pkgs/niri-kdeconnect-portal { };
in
{
  environment.systemPackages = [ pkgs.deskflow ];

  # if you're running the server on this box and want it reachable on LAN
  networking.firewall.allowedTCPPorts = [ 24800 ];

  # A deskflow *client* on Wayland does not touch the keyboard/mouse
  # directly: it asks xdg-desktop-portal for a RemoteDesktop session, gets an
  # EIS socket back, and injects everything through libei. niri has no
  # RemoteDesktop portal backend (see pkgs/niri-kdeconnect-portal), so under
  # niri that very first step fails and the client never connects at all:
  #
  #   ERROR: failed to initialize remote desktop session: CreateSession failed
  #
  # It looks like a TLS/fingerprint problem from the GUI -- the client just
  # never reaches a connected state -- but the TCP connection and the
  # certificates are fine, and so is the same deskflow.pem under Plasma, where
  # KWin's portal supplies RemoteDesktop. Only the input path is missing.
  #
  # So: add the bridge as a portal backend and point niri's portal config at
  # it for RemoteDesktop only. Everything else (ScreenCast via Mutter's API,
  # Access/Notification/Secret) keeps the routing programs.niri.enable set up;
  # xdg.portal.config.niri is an attrset, so this merges one key into it
  # rather than replacing it.
  xdg.portal = lib.mkIf config.programs.niri.enable {
    extraPortals = [ niri-kdeconnect-portal ];
    config.niri."org.freedesktop.impl.portal.RemoteDesktop" = "niri-kdeconnect";
  };

  # Nothing else to wire up: the package ships its own user unit, xdg.portal
  # puts it in systemd.packages and its D-Bus service file in
  # services.dbus.packages, so xdg-desktop-portal activates it on the first
  # CreateSession. Upstream's unit hardening (ProtectSystem=strict,
  # ProtectHome=read-only, AF_UNIX only) was checked against this session and
  # still lets the backend reach the Wayland socket under $XDG_RUNTIME_DIR, so
  # it is left alone.
}
