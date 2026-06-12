{ config, pkgs, ... }:

{
  imports = [ ./kakoune.nix ];
  
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "rileytuttle";
  home.homeDirectory = "/home/rileytuttle";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "26.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
    pavucontrol
    ptouch-print
    fzf
    blueman
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/rileytuttle/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  programs.bash = {
    enable = true;

      # shell aliases
      shellAliases = {
        gst = "git status";
        calc = "python3 -i -c \"from math import *; import numpy as np\"";
        hm-switch = "home-manager -f ~/Configs/nixos/home/pocket35.nix switch";
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

  programs.fzf = {
    enable = true;
    defaultOptions = [ "--layout=reverse" ];
  };
  
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  xfconf.settings = {
    "xfce4-session" = {
      "accessibility/OnscreenKeyboard" = false;
     };
     "xfsettingsd" = {
       "accessibility/OnscreenKeyboard" = false;
     };
  };

}
