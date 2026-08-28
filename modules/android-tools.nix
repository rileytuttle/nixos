{ config, pkgs, ... }:

{
  environment.systemPackages = [ pkgs.android-tools ];

  users.users.rileytuttle.extraGroups = [ "adbusers" ];
}
