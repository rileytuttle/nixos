# balena-cli plus the balena-plus wrapper (device-name resolution, fleet
# picker, login on demand, tunnel/logs/ps/uuid/devices helpers). The wrapper
# is aliased to `balena`; `\balena` skips the alias and runs the raw CLI,
# which is what pkgs.balena-cli below is for.
#
# The wrapper itself lives in its own repo (github:rileytuttle-havoc/balena-plus)
# rather than here, because colleagues need to install it on machines that
# have nothing to do with this config. It is a flake input, so there is one
# copy of the script, not two -- `nix flake update balena-plus` after changing
# it there.
#
# pkgs.balena-cli is deliberately still installed. The shared package does not
# carry one (it uses whatever balena is on PATH, so nobody installs a second
# ~630MB copy), which means supplying it is this module's job.
#
# The shell glue goes in ~/.bash_aliases rather than programs.bash.initExtra
# because rt-dellpromax-24's ~/.bashrc is Ubuntu's own, not home-manager's,
# and Ubuntu's stock .bashrc already sources ~/.bash_aliases.
{ pkgs, inputs, ... }:
let
  balena-plus = inputs.balena-plus.packages.${pkgs.stdenv.hostPlatform.system}.balena-plus;
in
{
  home.packages = [ pkgs.balena-cli balena-plus ];

  # Emits the `balena` alias plus both completion sources -- the wrapper's own
  # and balena-cli's oclif-generated one, which it generates on first run and
  # caches. Same line the standalone installer tells outside users to add.
  home.file.".bash_aliases".text = ''
    eval "$(${balena-plus}/bin/balena-plus shell-init bash)"
  '';
}
