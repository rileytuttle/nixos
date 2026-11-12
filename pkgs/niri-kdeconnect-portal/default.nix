# org.freedesktop.impl.portal.RemoteDesktop backend for niri.
#
# niri implements Mutter's ScreenCast D-Bus API, so xdg-desktop-portal-gnome
# can give it ScreenCast and Screenshot -- but it implements no
# org.gnome.Mutter.RemoteDesktop, so xdpg never exports
# org.freedesktop.impl.portal.RemoteDesktop at all. Anything that wants to
# *inject* input (deskflow as a client, KDE Connect's remote input, rustdesk)
# then dies the moment it asks the portal for a session:
#
#   deskflow: ERROR: failed to initialize remote desktop session: CreateSession failed
#   xdg-desktop-portal: A backend call failed: No such interface
#                       "org.freedesktop.impl.portal.RemoteDesktop"
#
# niri's own RemoteDesktop portal is still an unmerged PR (niri-wm/niri#1966,
# tracking issue #390). This bridge fills the gap in userspace instead: it is a
# standalone portal backend that answers CreateSession/SelectDevices/Start/
# ConnectToEIS, runs a libeis server for the libei client on the other end, and
# replays what it receives through the two input protocols niri *does* speak,
# zwlr_virtual_pointer_manager_v1 and zwp_virtual_keyboard_manager_v1.
#
# Despite the upstream name it is not KDE-Connect-specific; deskflow is a
# first-class caller (see docs/deskflow.md in the source). Drop this package
# the day niri ships the portal itself.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  wayland-scanner,
  qt6,
  wayland,
  libxkbcommon,
  libei,
  deskflow,
}:

stdenv.mkDerivation {
  pname = "niri-kdeconnect-portal";
  version = "0-unstable-2026-11-09";

  src = fetchFromGitHub {
    owner = "risenburn";
    repo = "niri-kdeconnect-fix";
    rev = "3a23d7de4d785bc3ab3e993901eb6947a139c98c";
    hash = "sha256-pdpt3H6uOnQPbbjRv8cCzGlJemG6MYzVFuwIQxHQrMg=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    wayland-scanner
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    qt6.qtbase
    wayland
    libxkbcommon
    libei # provides libeis-1.0.pc; without it the build vendors libei as a submodule
  ];

  # Qt Core + DBus only, no GUI and no Qt plugins to find.
  dontWrapQtApps = true;

  cmakeFlags = [
    # The portal authorizes a caller either by its portal app id or, for a
    # native (non-flatpak) session where the app id is empty, by comparing
    # readlink("/proc/<pid>/exe") against /usr/bin/deskflow-core or this one
    # exact path. Deskflow on NixOS is a makeBinaryWrapper, so the pid's exe
    # is the *wrapped* binary, not bin/deskflow-core -- see src/portal_backend
    # .cpp and src/security_policy.hpp. This is why the package depends on
    # deskflow: it pins the authorized store path, so a deskflow update
    # rebuilds the bridge with the new one instead of silently locking it out.
    (lib.cmakeFeature "NKCF_DESKFLOW_EXECUTABLE" "${deskflow}/bin/.deskflow-core-wrapped")

    # BUILD_TESTING is on by default via include(CTest), and the test targets
    # reference Threads::Threads without a find_package(Threads), so configure
    # fails outright with it enabled.
    (lib.cmakeBool "BUILD_TESTING" false)
  ];

  # NixOS collects user units from $out/etc/systemd/user and
  # $out/lib/systemd/user only (nixos/lib/systemd-lib.nix). Upstream's CMake
  # puts the unit in $out/share/systemd/user, where systemd.packages never
  # looks -- the shipped unit would be invisible, and any
  # systemd.user.services override of it in a module would then be written out
  # as a *full* replacement unit with no ExecStart or BusName at all instead of
  # a drop-in. The .portal and D-Bus service files are already where
  # xdg-desktop-portal and services.dbus.packages expect them.
  postInstall = ''
    mkdir -p "$out/lib/systemd"
    mv "$out/share/systemd/user" "$out/lib/systemd/user"
    rmdir "$out/share/systemd"
  '';

  meta = {
    description = "RemoteDesktop xdg-desktop-portal backend for niri, bridging libei to wlr virtual pointer/keyboard";
    homepage = "https://github.com/risenburn/niri-kdeconnect-fix";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "niri-kdeconnect-portal";
  };
}
