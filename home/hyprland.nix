{ pkgs, inputs, ... }:
{
  wayland.windowManager.hyprland = {
    enable = true;

    # set the flake package
    # package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    # portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    extraConfig =
      builtins.readFile "${inputs.dotfiles}/dotfiles/hypr/hyprland.lua"
      + ''
      require("local")
      '';
      # hl.bind("SUPER + B", function()
      #   -- hl.exec_cmd("PID=$(pidof ashell); echo $PID; kill -SIGUSR1 $PID")
      #   hl.exec_cmd('notify-send "Hyprland" "Keybind fired"')
      # end)
      # hl.on("hyprland.start", function()
      #   hl.exec_cmd("iio-hyprland")
      # end)
      # hl.bind("SUPER + R", hl.exec_cmd("MON=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .name'); CUR=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .transform'); NEXT=$(( (CUR + 1) % 4 )); hyprctl keyword monitor \"$MON,preferred,auto,1,transform,$NEXT\""))

    plugins = [
      inputs.hyprspace.packages.${pkgs.stdenv.hostPlatform.system}.Hyprspace
    ];
  };
  
  home.packages = with pkgs; [
    kdePackages.dolphin
    kitty
    gnome-terminal
    mako
    wl-clipboard
    hyprpolkitagent
    alsa-utils
    hyprpaper
    hyprpwcenter
    hyprsunset
    hypridle
    hyprlock
    hyprsysteminfo
    hyprgraphics
    brightnessctl
    playerctl
    inputs.ashell.packages.${pkgs.stdenv.hostPlatform.system}.default
    hyprlauncher
    jq
  ];

  home.file.".config/hypr/hypridle.conf".source = "${inputs.dotfiles}/dotfiles/hypr/hypridle.conf";
  home.file.".config/hypr/hyprpaper.conf".source = "${inputs.dotfiles}/dotfiles/hypr/hyprpaper.conf";
  home.file.".config/ashell".source = "${inputs.dotfiles}/dotfiles/ashell";
}
