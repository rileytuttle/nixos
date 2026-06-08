{ pkgs, config, inputs, ... }:
let niri = inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri;
in
{
  programs.niri.enable = true;
  security.polkit.enable = true;

  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "polkit-gnome-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
  };

  environment.systemPackages = with pkgs; [
    niri
    gnome-terminal
    wl-clipboard
    fuzzel
    swaylock
    swayidle
  ];

  systemd.user.services.swayidle = {
    description = "Idle manager for Wayland";
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.swayidle}/bin/swayidle -w \
          timeout 300 '${pkgs.swaylock}/bin/swaylock' \
          before-sleep '${pkgs.swaylock}/bin/swaylock' \
      '';
      Restart = "on-failure";
    };
  };

  environment.etc."niri/config.kdl" = {
    # or if it lives elsewhere:
    source = "${inputs.dotfiles}/dotfiles/niri/config.kdl";
  };

}
