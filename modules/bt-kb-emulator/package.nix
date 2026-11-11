# The programs, with no opinion about how the server gets started. Shared by
# module.nix (NixOS, declarative system service) and home.nix (home-manager
# on a foreign distro, where bt-kb-setup installs the unit imperatively).
{ lib
, stdenvNoCC
, python3
, makeWrapper
, bluez
, systemd
, wl-clipboard
, xclip
}:

let
  pythonEnv = python3.withPackages (ps: [
    ps.dbus-python
    ps.pygobject3
    ps.tkinter
  ]);

  # wl-paste for Wayland, xclip for X11 -- btkb_clip.py picks whichever the
  # session actually has, and falls back to Tk's own clipboard if neither.
  clipboardTools = lib.makeBinPath [ wl-clipboard xclip ];
in
stdenvNoCC.mkDerivation {
  pname = "bt-kb-emulator";
  version = "0.1.0";

  # Only the sources, so a stray __pycache__/ from running the scripts out
  # of the working tree can't change the derivation hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./hid_server.py
      ./keygrab.py
      ./btkb_send.py
      ./btkb_clip.py
      ./btkb_forget.py
      ./setup_system.py
      ./hid_keymap.py
      ./sdp_record.xml
    ];
  };

  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/share/bt-kb-emulator $out/bin
    cp hid_server.py keygrab.py btkb_send.py btkb_clip.py btkb_forget.py \
       setup_system.py hid_keymap.py sdp_record.xml $out/share/bt-kb-emulator/

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/bt-kb-hid-server \
      --add-flags "$out/share/bt-kb-emulator/hid_server.py" \
      --chdir "$out/share/bt-kb-emulator"

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/bt-kb-keygrab \
      --add-flags "$out/share/bt-kb-emulator/keygrab.py" \
      --chdir "$out/share/bt-kb-emulator" \
      --prefix PATH : ${clipboardTools}

    # GUI-free sender, for telling "the Bluetooth link is broken" apart
    # from "the capture window isn't seeing my keys".
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/bt-kb-send \
      --add-flags "$out/share/bt-kb-emulator/btkb_send.py" \
      --chdir "$out/share/bt-kb-emulator" \
      --prefix PATH : ${clipboardTools}

    # Clears this machine's half of a stale bond, scoped to devices that
    # actually connected as HID hosts. systemd for the optional --restart.
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/bt-kb-forget \
      --add-flags "$out/share/bt-kb-emulator/btkb_forget.py" \
      --chdir "$out/share/bt-kb-emulator" \
      --prefix PATH : ${lib.makeBinPath [ systemd ]}

    # Installs the system-level half on a non-NixOS host. Refuses to run on
    # NixOS, where module.nix owns all of this declaratively. btmgmt comes
    # from bluez for the best-effort Class of Device step.
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/bt-kb-setup \
      --add-flags "$out/share/bt-kb-emulator/setup_system.py" \
      --chdir "$out/share/bt-kb-emulator" \
      --prefix PATH : ${lib.makeBinPath [ bluez ]}
  '';

  meta = {
    description = "Bluetooth HID-device keyboard emulator (type on your phone from your PC)";
    platforms = lib.platforms.linux;
    mainProgram = "bt-kb-keygrab";
  };
}
