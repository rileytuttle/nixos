{
  description = "My NixOS config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";  # reuse the same nixpkgs, don't pull a second copy
    };
    dotfiles = {
      url = "github:rileytuttle/Configs";  # or wherever your dotfiles repo is
      flake = false;  # it's not a flake, just a source repo
    };
  };

  outputs = { self, nixpkgs, home-manager, dotfiles, ... }: {
    nixosConfigurations = {

      fw12 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit dotfiles; };
        modules = [
          ./hosts/fw12.nix
          ./modules/common.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.rileytuttle = import ./home/default.nix;
          }
        ];
      };

      desktop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/desktop.nix
          ./modules/common.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.rileytuttle = import ./home/default.nix;
          }
        ];
      };

    };
  };
}
