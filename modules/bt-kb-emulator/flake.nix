{
  description = "Bluetooth HID-device keyboard emulator (type on your phone from your PC)";

  # Lives inside github:rileytuttle/nixos for now (see the parent flake,
  # which pulls this in via `path:./modules/bt-kb-emulator`) but is a
  # self-contained flake on purpose, so it can move to its own repo later
  # with nothing but a URL change on the consuming side.
  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # NixOS host: `imports = [ inputs.bt-kb-emulator.nixosModules.default ];`
      # See README.md for the full writeup and the home-manager alternative.
      nixosModules.default = import ./module.nix;

      # home-manager on a non-NixOS host: `imports = [
      # inputs.bt-kb-emulator.homeManagerModules.default ];`, then run
      # `bt-kb-setup` once. Only installs the user-facing half -- see
      # home.nix and README.md.
      homeManagerModules.default = import ./home.nix;

      # `nix run github:rileytuttle/bt-kb-emulator` (once split out) or
      # `nix build` here directly. module.nix/home.nix build their own copy
      # via callPackage against the host's own pkgs, so this output is just
      # for standalone use.
      packages.${system}.default = pkgs.callPackage ./package.nix { };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system}.package = self.packages.${system}.default;
    };
}
