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
}
