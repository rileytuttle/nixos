# balena-cli plus the balena-plus.sh wrapper (device-name resolution, login
# on demand, tunnel/logs/ps/uuid/devices helpers). The wrapper installs as
# `balena-plus` and is aliased to `balena`; `\balena` skips the alias and
# runs the raw CLI, which is also installed here.
#
# The alias goes in ~/.bash_aliases rather than programs.bash.shellAliases
# because rt-dellpromax-24's ~/.bashrc is Ubuntu's own, not home-manager's,
# and Ubuntu's stock .bashrc already sources ~/.bash_aliases.
{ pkgs, ... }:
let
  balena-plus = pkgs.writeShellApplication {
    name = "balena-plus";
    runtimeInputs = with pkgs; [ balena-cli python3 fzf ];
    text = builtins.readFile ./balena-plus.sh;
  };

  # balena-cli doesn't install a bash completion file, but its oclif
  # autocomplete plugin generates one into the cache dir on demand. Do that
  # at build time so it tracks the packaged CLI version.
  balena-oclif-completion = pkgs.runCommand "balena-oclif-completion" { } ''
    export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/cache
    ${pkgs.balena-cli}/bin/balena autocomplete bash --refresh-cache
    install -Dm644 $XDG_CACHE_HOME/balena-cli/autocomplete/functions/bash/balena.bash $out
  '';
in
{
  home.packages = [ pkgs.balena-cli balena-plus ];

  # oclif's completion first (defines _balena_autocomplete), then ours,
  # which takes over `complete balena` and falls back to it.
  home.file.".bash_aliases".text = ''
    alias balena=balena-plus
    source ${balena-oclif-completion}
    source ${./balena-completion.bash}
  '';
}
