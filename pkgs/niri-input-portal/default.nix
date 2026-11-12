# org.freedesktop.impl.portal.InputCapture backend for niri.
#
# The mirror image of pkgs/niri-kdeconnect-portal, and the two are not
# interchangeable -- which one a host needs depends on which end of the
# deskflow link it is:
#
#   deskflow CLIENT  (receives input)  -> portal RemoteDesktop -> injects
#   deskflow SERVER  (sends input)     -> portal InputCapture  -> captures
#
# fw12 is the client, so it got the RemoteDesktop bridge. rt-dellpromax-24 is
# the server (coreMode=2), and under niri it fails one step earlier, in the
# other portal entirely:
#
#   ERROR: failed to initialize input capture session, quitting: CreateSession failed
#
# Note the wording -- "input capture session", not "remote desktop session".
# The RemoteDesktop bridge does nothing for this.
#
# Why it fails: xdg-desktop-portal-gnome implements the InputCapture backend
# on top of org.gnome.Mutter.InputCapture. niri speaks Mutter's ScreenCast,
# DisplayConfig, ServiceChannel, Shell.Introspect and Shell.Screenshot APIs --
# but not Mutter.InputCapture -- so xdp-gnome never publishes the backend.
# The *frontend* interface is still there (which is why deskflow gets a failed
# method call rather than "No such interface", the way it does for
# GlobalShortcuts in the same log), it just reports SupportedCapabilities = 0,
# and CreateSession is refused.
#
# This backend publishes the missing interface directly, built on the Wayland
# protocols niri does support: wlr-layer-shell for the barrier surfaces,
# pointer-constraints and relative-pointer for the capture itself, and
# ext_data_control_manager_v1 for the clipboard. It runs its own EIS server
# (via the pure-Rust `reis` crate, so no libei C dependency) and hands the
# socket to deskflow.
#
# Drop this package the day niri implements InputCapture itself -- tracking
# issue niri-wm/niri#821.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  wayland,
  libxkbcommon,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "niri-input-portal";
  version = "0-unstable-2026-10-20";

  src = fetchFromGitHub {
    owner = "Qingswe";
    repo = "niri-input-portal";
    rev = "49f82a63ca53b0137ad4eea08f4cd9d72642a22b";
    hash = "sha256-qk4A9KNU+b4U5lr9Pl4oVSasMDpw0BCwdV4b5vS1U5k=";
  };

  cargoHash = "sha256-UD9jSOyY+p7JbgvfzI1zcRisITFvjGoKWscvqzylldg=";

  nativeBuildInputs = [ pkg-config ];

  # wayland-client links libwayland-client at build time (it only dlopens it
  # with the `dlopen` feature, which smithay-client-toolkit does not enable).
  # smithay-client-toolkit adds libxkbcommon on top, for the keymap it hands
  # the EIS client.
  buildInputs = [
    wayland
    libxkbcommon
  ];

  # Upstream ships no cargo install hook for its data files -- install.sh does
  # it by hand, into /usr and $HOME. Do the same here, but into $out and with
  # the two hardcoded /usr/lib/niri-input-portal paths rewritten to the store.
  #
  # The .portal and D-Bus service files land where XDG_DATA_DIRS can see them
  # once the package is in the profile; home/niri-generic-linux.nix already
  # puts ~/.nix-profile/share on XDG_DATA_DIRS for the systemd user manager,
  # which is what both xdg-desktop-portal and the session bus read.
  postInstall = ''
    install -Dm644 data/niri-input.portal \
      "$out/share/xdg-desktop-portal/portals/niri-input.portal"

    install -Dm644 data/org.freedesktop.impl.portal.desktop.niri-input.service \
      "$out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.niri-input.service"

    # Shipped for completeness/reuse only. The standalone home-manager host
    # does not read it -- home-manager has no systemd.packages equivalent, so
    # home/deskflow-generic-linux.nix declares the unit itself (same as
    # install.sh, which also writes it into ~/.config/systemd/user).
    #
    # Written to lib/ rather than share/ because nixpkgs' fixup hook moves
    # lib/systemd/user -> share/systemd/user and leaves a symlink behind, so
    # installing it here ends up readable under both spellings. Note
    # pkgs/niri-kdeconnect-portal does that same move by hand, in the opposite
    # direction -- it is a stdenv.mkDerivation and never runs this hook.
    install -Dm644 data/niri-input-portal.service \
      "$out/lib/systemd/user/niri-input-portal.service"

    substituteInPlace \
      "$out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.niri-input.service" \
      "$out/lib/systemd/user/niri-input-portal.service" \
      --replace-fail /usr/lib/niri-input-portal "$out/bin/niri-input-portal"
  '';

  meta = {
    description = "InputCapture xdg-desktop-portal backend for niri, so deskflow/Synergy/Input Leap can act as a server";
    homepage = "https://github.com/Qingswe/niri-input-portal";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "niri-input-portal";
  };
})
