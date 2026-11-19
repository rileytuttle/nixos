{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./fw12-rack-headless-hardware-configuration.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
    ../modules/docker.nix
  ];

  networking.hostName = "fw12-rack-headless";

  # This is fw12's original mainboard -- 13th-gen Intel (Raptor Lake), i915
  # iGPU, no NPU -- pulled when fw12 itself moved to the Core Series 3 board
  # (see hosts/fw12.nix). Reused here headless in a server rack rather than
  # thrown out. The nixos-hardware module for it is pulled in by flake.nix.
  hardware.enableRedistributableFirmware = true;

  # Headless: no monitor plugged in, no desktop session to run. common.nix
  # turns xserver/sddm/plasma6 on unconditionally (fine for fw12 and
  # elitedesk, which both have a screen); override all three off here rather
  # than build and never use one.
  services.xserver.enable = lib.mkForce false;
  services.displayManager.sddm.enable = lib.mkForce false;
  services.desktopManager.plasma6.enable = lib.mkForce false;

  # No battery, lid, touchpad or Bluetooth peripherals on a board sitting in
  # a rack chassis on wall power -- none of fw12.nix's laptop power
  # management (TLP/thermald/sleep-hibernate/bluetooth/libinput/kdeconnect)
  # applies here.

  # Claude Code in a container, from home/claude-container.nix. Enabled here
  # rather than in the module because it needs a container runtime, and
  # ../modules/docker.nix (imported above) is what provides one on this host.
  #
  # runtime is left to auto-detect: docker is what is installed today, and the
  # tool handles a rootful daemon by dropping to this uid inside. If podman
  # ever lands here it gets picked up first, and then nothing has to chown.
  home-manager.users.rileytuttle.programs.claude-container = {
    enable = true;
    aliases = [
      "claude-c"
      "claude"
    ];
  };

  # Escape hatch out of the container above: runs the real Claude Code
  # binary directly on this host, no container/sandbox around it. Named
  # away from `claude`/`claude-c` on purpose -- those stay pointed at the
  # container so the sandboxed path remains the default, and this one is
  # only reached for the rare case that genuinely needs host-level access
  # (e.g. a real nixos-rebuild, or touching hardware the container can't see).
  home-manager.users.rileytuttle.home.packages = [
    (pkgs.writeShellScriptBin "claude-raw" ''
      exec ${pkgs.claude-code}/bin/claude "$@"
    '')
  ];
}
