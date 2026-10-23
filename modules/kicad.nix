{ config, pkgs, ... }:

{
  # Full KiCad -- includes the symbol/footprint/3d-model libraries.
  # pkgs.kicad-small drops the libraries if disk space ever matters.
  environment.systemPackages = with pkgs; [
    kicad
  ];
}
