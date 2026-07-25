{ config, pkgs, ... }:

{
  # mergerfs binary + fuse support
  environment.systemPackages = with pkgs; [ mergerfs ];

  # Let mergerfs (running as root via fuse) present files as other users --
  # needed for e.g. jellyfin to read files it doesn't directly own.
  programs.fuse.userAllowOther = true;

  ##########################################################################
  # Underlying disks
  #
  # Add one fileSystems entry per physical drive you pool. Mount points
  # must follow the /mnt/diskN naming convention below -- mergerfs.nix's
  # device glob depends on it.
  #
  #
  # To expand later:
  #   1. Find the new drive's device name: `lsblk` (e.g. /dev/sdc)
  #   2. WIPE IT -- this destroys all existing data/partitions on the drive:
  #        sudo wipefs -a /dev/sdc
  #   3. Partition it (single partition, whole disk):
  #        sudo parted /dev/sdc -- mklabel gpt
  #        sudo parted /dev/sdc -- mkpart primary ext4 0% 100%
  #   4. Format the new partition:
  #        sudo mkfs.ext4 /dev/sdc1
  #   5. Find its UUID: `lsblk -f`
  #   6. Add a new fileSystems."/mnt/diskN" block following the same
  #      pattern below, rebuild. The mergerfs mount picks it up
  #      automatically -- no change needed to the merge stanza itself.
  #
  ##########################################################################

  fileSystems."/mnt/disk1" = {
    device = "/dev/disk/by-uuid/2adf619f-908b-40a3-aee8-88011520807a";
    fsType = "ext4";
  };

  fileSystems."/mnt/disk2" = {
    device = "/dev/disk/by-uuid/3e7fbf13-830d-4403-b6f8-d3ddfd9ad283";
    fsType = "ext4";
  };

  fileSystems."/mnt/disk3" = {
    device = "/dev/disk/by-uuid/3c4bd2aa-47e7-4f11-9b63-570913913edb";
    fsType = "ext4";
  };

  # fileSystems."/mnt/diskN" = {
  #   device = "/dev/disk/by-uuid/REPLACE-WITH-DISK2-UUID";
  #   fsType = "ext4";
  # };

  ##########################################################################
  # Pooled mount
  #
  # The "/mnt/disk*" glob means any current or future /mnt/diskN mount
  # gets included automatically at mount time -- this line never needs
  # to change when you add drives.
  ##########################################################################

  fileSystems."/mnt/storage" = {
    fsType = "fuse.mergerfs";
    device = "/mnt/disk*";
    options = [
      "defaults"
      "allow_other"
      "use_ino"
      "cache.files=partial"
      "dropcacheonclose=true"
      "category.create=mfs"   # new files go to disk with most free space
      "moveonenospc=true"     # move file to another disk if one fills up
      "minfreespace=50G"
    ];
    # Ensures systemd mounts disk1 (and disk2, disk3... once added) before
    # attempting the merged mount.
    depends = [ "/mnt/disk1" "/mnt/disk2" "/mnt/disk3" ];
  };

  # Shared group so services (jellyfin, *arr stack, etc.) can read/write
  # into the pool without needing individual user ownership.
  users.groups.media = { };
}
