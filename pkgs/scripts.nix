# Personal command-line tools, as first-class nix packages.
#
# Each is built with the writer that type-checks it at build time, so a broken
# edit fails `nix flake check` rather than failing later in your shell:
#
#   writeShellApplication    runs shellcheck, applies `set -euo pipefail`
#   writers.writePython3Bin  runs flake8, pins the interpreter in the shebang
#
# The sources in ./scripts are written FOR these writers -- each carries a
# `# shellcheck shell=bash` directive, sets its own flags and quotes its
# expansions -- rather than being legacy files carried along inside a PATH
# wrapper. Same pattern as home/balena.nix.
#
# PATH note: shic does its privileged work through `sudo nmcli` / `sudo
# iptables`, and sudo resets PATH to its own secure_path, so runtimeInputs
# cannot reach those. They are declared for the unprivileged calls the script
# also makes (iw, `nmcli connection show`, grep -P, awk, qrencode). sudo
# itself is deliberately absent: it must be the setuid wrapper in
# /run/wrappers/bin, never a copy from the store.
{ pkgs }:

{
  # SHare Internet Connection. Builds a NetworkManager shared connection
  # (ethernet or a WiFi AP) and the matching forward/MASQUERADE rules.
  # Completions for it live in home/auto-completes.sh.
  shic = pkgs.writeShellApplication {
    name = "shic";
    runtimeInputs = with pkgs; [
      iw
      networkmanager # nmcli
      iptables
      iproute2 # ip
      procps # sysctl
      gnugrep # needs grep -P
      gawk
      coreutils
      qrencode # QR for the AP credentials
      xdg-utils # xdg-open on the generated PNG
    ];
    text = builtins.readFile ./scripts/shic.sh;
    meta.description = "Share an internet connection over another interface (ethernet or WiFi AP)";
  };

  # rsync wrapper for pushing a music library onto a mounted iPod.
  sync-ipod = pkgs.writeShellApplication {
    name = "sync-ipod";
    runtimeInputs = with pkgs; [
      rsync
      coreutils
    ];
    text = builtins.readFile ./scripts/sync-ipod.sh;
    meta.description = "rsync a music library onto a mounted iPod, with FAT-safe timestamps";
  };

  # Named git-clear so `git clear` finds it on PATH as a subcommand.
  git-clear = pkgs.writeShellApplication {
    name = "git-clear";
    runtimeInputs = [ pkgs.git ];
    text = builtins.readFile ./scripts/git-clear.sh;
    meta.description = "Discard all tracked changes on the current branch";
  };

  # Unpacks a nested comic release (zip -> split RAR4 -> PDF/CBR/CBZ/images)
  # into a .cbz. Pure stdlib by design -- no unrar or poppler -- so there are
  # no libraries to declare.
  comic2cbz = pkgs.writers.writePython3Bin "comic2cbz" {
    libraries = [ ];
    # Style-only codes, matching how the script is written throughout.
    # The F-codes (undefined names, unused imports) stay ON -- they are
    # the reason for checking at all, and they already earned it: flake8
    # caught an unused `import sys` here, now removed.
    flakeIgnore = [
      "E127" # continuation line over-indented
      "E265" # block comment should start with '# '
      "E302" # expected 2 blank lines
      "E305" # expected 2 blank lines after a def
      "E401" # multiple imports on one line
      "E501" # line too long
      "E731" # lambda assigned to a name
      "W503" # line break before binary operator
      "W504" # line break after binary operator
    ];
  } (builtins.readFile ./scripts/comic2cbz);
}
