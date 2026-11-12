# Riley's personal-machine home-manager profile: identity plus the two
# layers. Thin on purpose -- the content lives in core.nix (portable) and
# apps-personal.nix (GUI), so another host can take one without the other.
{
  ...
}:

{
  imports = [
    ./core.nix
    ./apps-personal.nix
  ];

  home.username = "rileytuttle";
  home.homeDirectory = "/home/rileytuttle";
  home.stateVersion = "26.05";

  # Identity, same as the three options above it. core.nix sets everything
  # about git *except* who you are, because it is also imported by the work
  # machine, where commits should not silently go out under this address.
  programs.git.settings.user.email = "rileytuttle@gmail.com";
}
