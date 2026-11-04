# Portable user environment: shell, git, editor config, CLI tools.
#
# MUST NOT assume NixOS. fw12 and elitedesk get this via home/default.nix as
# NixOS home-manager users; the intent is that rt-dellpromax-24 (Ubuntu, nix
# as a plain package manager) can import this file directly once its manual
# installs are retired. So: nothing here may reference a NixOS module, and
# identity (home.username / homeDirectory / stateVersion) is deliberately
# left to the importing host rather than set here -- those differ per machine
# and would collide.
{
  pkgs,
  ...
}:

let
  # The scripts that survived the Configs cleanup, as derivations.
  scripts = import ../pkgs/scripts.nix { inherit pkgs; };
in
{
  # Git. Declared here in full rather than copied in as a ~/.gitconfig file:
  # home-manager writes programs.git to ~/.config/git/config, and git reads
  # ~/.gitconfig at *higher* precedence, so a copied file silently shadows
  # whatever is set here. One source, no shadowing.
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Riley Tuttle";
        email = "rileytuttle@gmail.com";
      };
      diff = {
        algorithm = "histogram";
        colorMoved = "plain";
        # Spelled mnemonicPreix in the old dotfiles/.gitconfig, which git
        # does not recognise and silently ignored. Fixed on the way in.
        mnemonicPrefix = true;
        renames = true;
      };
      help.autocorrect = "prompt";
      commit.verbose = true;
      core.editor = "kak";
    };
  };

  # CLI tools. GUI applications live in home/apps-personal.nix.
  home.packages = [
    scripts.shic
    scripts.sync-ipod
    scripts.git-clear
    scripts.comic2cbz
  ]
  ++ (with pkgs; [
    fzf
    glow
    iw
    jq
    keychain
    opencode
    python3
    qrencode
    ripgrep
    tmux
    wl-clipboard
    xclip
  ]);

  home.file.".config/kak/kakrc".source = ../dotfiles/kakrc;
  home.file.".tmux.conf".source = ../dotfiles/tmux.conf;

  programs.bash = {
    enable = true;

    # shell aliases
    shellAliases = {
      gst = "git status";
      calc = "python3 -i -c \"from math import *; import numpy as np\"";
      rebuild = "sudo nixos-rebuild switch --flake $HOME/nixos#$(hostname)";
      update = "nix flake update --flake $HOME/nixos";
    };

    # runs in every interactive shell (equivalent of .bashrc additions)
    initExtra = ''
      # better history
      HISTSIZE=10000
      HISTFILESIZE=20000
      HISTCONTROL=ignoreboth   # ignore duplicates and lines starting with space
      shopt -s histappend      # append rather than overwrite history

      # auto-correct minor cd typos
      shopt -s cdspell

      # a nice prompt - shows user@host:dir and git branch
      parse_git_branch() {
        git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
      }
      export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\[\033[33m\]$(parse_git_branch)\[\033[00m\]\$ '

      # fzf keybindings if you have it installed
      export FZF_CTRL_R_OPTS="--layout=reverse"
      [ -f ~/.fzf.bash ] && source ~/.fzf.bash
      eval "$(${pkgs.fzf}/bin/fzf --bash)"
      # bind up arrow to search history by partial command
      bind '"\e[A": history-search-backward'
      # bind down arrow to search history by partial command
      bind '"\e[B": history-search-forward'

      # Shell functions (gb/gbd/gco via fzf-tmux) and completions. Sourced by
      # store path, so they need no checkout on disk to exist.
      source ${./git-scripts.sh}
      source ${./auto-completes.sh}
      alias gst="git status"

      # makes it so tab complete doesnt care about case 
      bind "set completion-ignore-case on"
      # makes it so the - and _ is same in tab completion
      bind "set completion-map-case on"
      # makes it so only single tab press will bring up completion options
      bind "set show-all-if-ambiguous on"
      eval $(keychain --eval --quiet ~/.ssh/id_ed25519)
    '';

    # runs only in login shells (equivalent of .bash_profile)
    profileExtra = ''
      export EDITOR="kak";
      export VISUAL="kak";
    '';
  };

  programs.fzf = {
    enable = true;
    defaultOptions = [ "--layout=reverse" ];
  };

  services.ssh-agent.enable = true;
}
