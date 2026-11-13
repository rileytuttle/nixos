{
  config,
  pkgs,
  inputs,
  ...
}:

{
  # Pull in the hardware scan NixOS generated at install time
  imports = [
    ./fw12-hardware-configuration.nix
    ../modules/kanata.nix
    ../modules/ssh.nix
    ../modules/tailscale.nix
    ../modules/kde.nix
    ../modules/transmission.nix
    ../modules/steam.nix
    ../modules/nzbget.nix
    ../modules/bambustudio.nix
    ../modules/deskflow.nix
    ../modules/local-nginx.nix
    ../modules/android-tools.nix
    ../modules/niri.nix
    ../modules/smart-sleep.nix
    ../modules/docker.nix
    ../modules/kicad.nix
    ../modules/tdarr-node.nix
    inputs.bt-kb-emulator.nixosModules.default
  ];

  networking.hostName = "fw12"; # whatever you want

  # WiFi is handled by NetworkManager (already enabled in common.nix)
  # but laptops often need firmware
  hardware.enableRedistributableFirmware = true;

  # The Core Series 3 iGPU (8086:fd80) has no i915 PCI id -- only xe claims
  # it. nixos-hardware's default here is i915, which means stage 1 loads a
  # driver that can never bind and KMS waits for udev in stage 2.
  # hardware.cpu.intel.npu.enable for this board's NPU (8086:fd3e) comes
  # from the generated hardware config, not from here.
  hardware.intelgpu.driver = "xe";

  # Suspend first, then hibernate to disk once the battery is actually at
  # risk. There is no choice to make about *which* suspend: this mainboard
  # has no S3 at all -- /sys/power/mem_sleep offers only s2idle, and
  # /proc/acpi/wakeup lists S4 (never S3) against every wake device. So
  # "suspend" here always means s2idle, i.e. hardware S0ix, and
  # mem_sleep_default=deep would be a no-op. Nothing to set for that;
  # MemorySleepMode is deliberately left unset because s2idle is the only
  # value the kernel would accept anyway.
  #
  # The hand-off to hibernate is battery-driven rather than on a short
  # timer. With a battery present, systemd arms the ACPI _BTP low-battery
  # alarm first and uses HibernateDelaySec only as an additional, earlier
  # deadline -- whichever fires first (systemd-sleep.conf(5)). This battery
  # does support _BTP (/sys/class/power_supply/BAT1/alarm is populated, at
  # ~10% of charge_full), so the alarm is the mechanism that normally wins.
  #
  # HibernateOnACPower = false is the point of the pair: docked on AC it
  # stays in S0ix indefinitely and never writes a 15G image, and the 2h
  # countdown only starts once AC is unplugged. That option is documented
  # as having no effect unless HibernateDelaySec is also set, which is why
  # the delay stays here instead of being dropped for the default.
  #
  # Every way of getting here (lid, DMS power menu, DMS idle timeout) goes
  # through `smart-sleep suspend-then-hibernate`, which closes Bitwarden
  # first -- its secret memory blocks hibernation kernel-wide. See
  # modules/smart-sleep.nix.
  systemd.sleep.settings.Sleep = {
    # Fallback list: "platform" needs ACPI to have registered
    # hibernation_ops, and systemd falls through to "shutdown" by itself if
    # it didn't. `cat /sys/power/disk` shows what the kernel actually
    # offers (it reads "[disabled]" whenever hibernation is unavailable).
    HibernateMode = "platform shutdown";
    HibernateDelaySec = "2h";
    HibernateOnACPower = false;
  };

  # Power management
  boot.resumeDevice = "/dev/disk/by-uuid/bcddfcc6-5946-4b9d-b288-904520de5ac0";

  # DMS idle/power-menu actions. Suspend behavior stays "Suspend" (0) on
  # purpose: DMS's own SuspendThenHibernate behavior calls systemctl
  # directly and ignores customPowerActionSuspend, which would skip
  # closing Bitwarden. Timeouts are in seconds.
  home-manager.users.rileytuttle.programs.dank-material-shell.settings = {
    customPowerActionSuspend = "smart-sleep suspend-then-hibernate";
    customPowerActionHibernate = "smart-sleep hibernate";
    lockBeforeSuspend = true;
    batteryLockTimeout = 300;
    batterySuspendTimeout = 600;
    batterySuspendBehavior = 0;
    acLockTimeout = 900;
    acSuspendTimeout = 1800;
    acSuspendBehavior = 0;
  };

  # Local docker registry on the network (no TLS), so pulls/pushes to it
  # aren't rejected for lacking HTTPS.
  virtualisation.docker.daemon.settings."insecure-registries" = [
    "192.168.1.12:5050"
  ];

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

  services.power-profiles-daemon.enable = false;
  services.thermald.enable = true;

  # Better battery life with TLP (alternative to power-profiles-daemon)
  services.tlp.enable = true;

  # Touchpad
  services.libinput.enable = true;

  # Bluetooth
  hardware.bluetooth.enable = true;
  # services.blueman.enable = true;

  # Thunderbolt device authorization. The domain runs at security=user, so the
  # PCIe tunnel (and with it the dock's USB hub) stays down until something
  # authorizes the device -- DP tunneling comes up regardless, which is why a
  # dock looks "half working". boltd does the authorizing and remembers
  # enrolled docks; it also pulls in the plasma-thunderbolt KCM.
  services.hardware.bolt.enable = true;

  # Screen brightness control
  users.users.rileytuttle.extraGroups = [
    "video" # needed for light
    "dialout"
  ];

  # Second account on this laptop: Courtney, a plain Plasma desktop user.
  # Declared here rather than in modules/common.nix because that file is
  # shared with elitedesk, and this account only belongs on the laptop.
  #
  # No "wheel": this is not an admin account, so no sudo and no
  # nixos-rebuild. The other groups are what a desktop session actually
  # needs -- networkmanager to pick a WiFi network without a polkit prompt
  # for a password they do not have, video/audio for the seat.
  #
  # No password here on purpose. Passwords on this host are imperative
  # (mutableUsers stays at its default of true and nothing in this repo
  # sets hashedPassword), which keeps hashes out of a public git repo --
  # set it once with `sudo passwd courtneycooke` after the first switch.
  users.users.courtneycooke = {
    isNormalUser = true;
    description = "Courtney Cooke";
    extraGroups = [
      "networkmanager"
      "video"
      "audio"
    ];
  };

  # Laptop-only packages
  environment.systemPackages = with pkgs; [
    powertop
    acpi
    gnome-power-manager
    chromium
  ];

  nixpkgs.config.permittedInsecurePackages = [
    "electron-39.8.10"
  ];

  programs.kdeconnect.enable = true;
}
