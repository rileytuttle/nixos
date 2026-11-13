# Courtney's home-manager profile: a plain desktop account for web browsing
# and the usual everyday files.
#
# Deliberately does NOT import home/core.nix or home/apps-personal.nix.
# core.nix carries Riley's identity (git user.name, the keychain/ssh-agent
# line, the kakrc) and a developer toolchain this account has no use for, and
# apps-personal.nix pulls in a 3D slicer and the rest of it. The desktop here
# is Plasma 6 from modules/kde.nix, which already supplies the file manager,
# PDF viewer, image viewer, archive tool and screenshot tool -- so this file
# only has to add what Plasma does not ship.
{
  pkgs,
  ...
}:

{
  home.username = "courtneycooke";
  home.homeDirectory = "/home/courtneycooke";
  home.stateVersion = "26.05";

  # The home-manager firefox module rather than just the package: it means a
  # policy/profile setting can be added here later without reaching for
  # about:config.
  programs.firefox.enable = true;

  home.packages = with pkgs; [
    thunderbird # email
    libreoffice-qt # documents; the Qt build to match Plasma
    vlc # anything Plasma's Elisa/Dragon won't play
  ];
}
