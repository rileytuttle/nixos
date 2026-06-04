{ config, pkgs, inputs, ... }:

{
  home.username = "rileytuttle";
  home.homeDirectory = "/home/rileytuttle";

  # Git
  programs.git = {
    enable = true;
    settings.user.name = "Riley Tuttle";
  };

  # programs.hyprland = {
  #   enable = true;
  #   # set the flake package
  #   package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
  #   # make sure to also set the portal package, so that they are in sync
  #   portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  # };

  # User packages (installed just for your user, not system-wide)
  home.packages = with pkgs; [
    fzf
    tmux 
    firefox
    signal-desktop
    spotify
    xclip
    qrencode
    openscad
    prusa-slicer
    deskflow
    xournalpp
    ripgrep
    slack
    bitwarden-desktop
    rpi-imager
    jellyfin-media-player
    discord
    spotify
    python3
  ];

  home.file.".config/kak/kakrc".source = "${inputs.dotfiles}/dotfiles/kakrc/kakrc-hyprland";
  home.file.".tmux.conf".source = "${inputs.dotfiles}/dotfiles/.tmux.conf";
  home.file.".gitconfig".source = "${inputs.dotfiles}/dotfiles/.gitconfig";

  programs.bash = {
    enable = true;

      # shell aliases
      shellAliases = {
        gst = "git status";
        calc = "python3 -i -c \"from math import *; import numpy as np\"";
        #rebuild = "sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)";
        #update = "sudo nix flake update /etc/nixos";
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

        [ -f ~/Configs/bash-scripts/git-scripts.sh ] && source ~/Configs/bash-scripts/git-scripts.sh
        [ -f ~/Configs/bash-scripts/auto-completes.sh ] && source ~/Configs/bash-scripts/auto-completes.sh ]
        alias gst="git status"

        # makes it so tab complete doesnt care about case 
        bind "set completion-ignore-case on"
        # makes it so the - and _ is same in tab completion
        bind "set completion-map-case on"
        # makes it so only single tab press will bring up completion options
        bind "set show-all-if-ambiguous on"
      '';

      # runs only in login shells (equivalent of .bash_profile)
      profileExtra = ''
        export EDITOR="kak";
        export VISUAL="kak";
      '';
    };

    home.sessionPath = [
      "$HOME/Configs/scripts"
    ];

    programs.fzf = {
      enable = true;
      defaultOptions = [ "--layout=reverse" ];
    };

  home.file.".config/hypr".source = "${inputs.dotfiles}/dotfiles/hypr";
  home.file.".config/ashell".source = "${inputs.dotfiles}/dotfiles/ashell";

  home.stateVersion = "26.05";
}
