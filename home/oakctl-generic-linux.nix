# rt-dellpromax-24-only home-manager module (wired in flake.nix).
#
# oakctl is Luxonis' CLI for OAK4 / RVC4 devices. It is NOT installed from
# nix here, even though nixpkgs has an `oakctl` package, because that package
# is far behind: the pinned nixpkgs carries 0.16.5 while upstream is on
# 0.31.1 as of 2026-11-12. oakctl talks to device-side firmware that moves
# with it, so a stale CLI is not a cosmetic problem -- it is the usual source
# of "that subcommand does not exist" against a device that is on current
# firmware. (If nixpkgs ever catches up, `home.packages = [ pkgs.oakctl ];`
# replaces this whole file.)
#
# So it comes from upstream's installer, the way Luxonis ships it, and this
# module does the two things nix still has to do around that:
#
#   1. put the installer on PATH as `oakctl-install`, with the one flag that
#      matters on this host (--no-modify-path), rather than leaving a
#      curl-pipe-bash line to be remembered and retyped;
#   2. put ~/.local/bin -- where the installer lands the binary -- on PATH
#      from home-manager's ~/.bashrc, since home-manager owns that file now
#      and the installer is no longer allowed to edit it.
#
# What this module deliberately does NOT do is install oakctl itself. The
# binary is mutable state in ~/.local/bin that `oakctl self-update` keeps
# current; nix only supplies the entry point. Run `oakctl-install` once after
# a fresh machine, and `oakctl self-update` (or `oakctl-install` again)
# whenever a device wants a newer CLI.
{
  config,
  pkgs,
  ...
}:

let
  # Where upstream's installer puts the binary. Not configurable -- the
  # installer hardcodes $HOME/.local/bin -- so this is a statement of fact
  # about it, not a choice being made here.
  localBin = "${config.home.homeDirectory}/.local/bin";

  # `bash -c "$(curl -fsSL .../oakctl-installer.sh)"`, which is the line
  # Luxonis documents, with two changes.
  #
  # --no-modify-path is the load-bearing one. Without it the installer
  # appends its own PATH block to ~/.bashrc, ~/.zshrc and ~/.profile. On this
  # host ~/.bashrc is a home-manager symlink into the nix store, so that edit
  # either fails outright or -- worse, if the file has been copied loose --
  # silently disappears at the next `home-manager switch`. The PATH entry is
  # declared below instead, which is the whole point of this module.
  #
  # The second change is fetching to a file rather than substituting the
  # script into `bash -c`. With command substitution a failed download
  # collapses to `bash -c ""`, which exits 0 and looks exactly like a
  # successful install; `set -o pipefail` does not help, because there is no
  # pipe. Downloading first means curl's own --fail is what decides.
  #
  # Extra arguments are passed through, so the installer's own flags still
  # work: --skip-usbd, --skip-udev, --enable-usbd. Worth knowing that the
  # default path asks for sudo -- the installer has oakctl drop udev rules in
  # /etc/udev/rules.d and set up the usbd service, which is root-owned state
  # home-manager has no way to express on a non-NixOS host (same situation as
  # kanata-host-setup in home/kanata-generic-linux.nix).
  oakctl-install = pkgs.writeShellApplication {
    name = "oakctl-install";
    runtimeInputs = with pkgs; [
      curl
      coreutils
    ];
    text = ''
      url=https://oakctl-releases.luxonis.com/oakctl-installer.sh

      staging=$(mktemp -d)
      trap 'rm -rf "$staging"' EXIT

      echo "==> fetching $url"
      curl --fail --silent --show-error --location "$url" \
        -o "$staging/oakctl-installer.sh"

      echo "==> running the oakctl installer (target: ${localBin})"
      bash "$staging/oakctl-installer.sh" --no-modify-path "$@"
    '';
  };
in
{
  home.packages = [
    oakctl-install # `oakctl-install [--skip-usbd|--skip-udev|--enable-usbd]`
  ];

  # The PATH entry the installer would have written, declared instead.
  #
  # Guarded so it does not stack up a duplicate entry per nested shell. That
  # is not hypothetical here: home/niri-generic-linux.nix already puts
  # ~/.local/bin first on PATH for the graphical session via
  # ~/.config/environment.d, so under niri every shell already has it and
  # this is a no-op. It exists for the shells that file does not reach --
  # ssh, a tty, anything started from Ubuntu's own GNOME session.
  #
  # In ~/.bashrc rather than home.sessionPath on purpose. sessionPath lands
  # in hm-session-vars.sh, which is sourced from ~/.profile -- and gdm execs
  # the session directly without sourcing it, which is the same reason
  # niri-generic-linux.nix needs its environment.d file at all.
  programs.bash.initExtra = ''
    # oakctl installs itself here; see home/oakctl-generic-linux.nix.
    case ":$PATH:" in
      *":${localBin}:"*) ;;
      *) export PATH="${localBin}:$PATH" ;;
    esac
  '';
}
