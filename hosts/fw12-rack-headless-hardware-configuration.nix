# PLACEHOLDER -- this is NOT a real `nixos-generate-config` scan.
#
# This board is the original fw12 mainboard: 13th-gen Intel (Raptor Lake),
# pulled out when fw12 was upgraded to the Core Series 3 board (see
# hosts/fw12.nix and hosts/fw12-hardware-configuration.nix for the new
# board's scan). It's being redeployed headless in a server rack instead of
# thrown out, so this file is modeled on that board's pre-upgrade scan
# (`git show b666a9c:hosts/fw12-hardware-configuration.nix`) rather than
# generated fresh, since the actual install (new disk, new UUIDs) hasn't
# happened yet.
#
# Once it's physically installed, boot it, let it take the hostname
# fw12-rack-headless, and run `nix run .#refresh-hardware-config` on the
# machine itself -- that overwrites this file with the real scan (real
# filesystem UUIDs, whatever disk/NIC modules the actual chassis needs).
# Review the diff it prints before rebuilding.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # TODO: replaced by the real scan once installed -- these UUIDs don't
  # correspond to any actual disk yet.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  # No swap/hibernate partition assumed -- this is a headless server, not a
  # laptop. Add one here (or let the real scan add it) if it turns out to
  # need swap.
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
