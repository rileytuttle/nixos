{
  description = "My NixOS config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";  # reuse the same nixpkgs, don't pull a second copy
    };
    dotfiles = {
      url = "github:rileytuttle/Configs";  # or wherever your dotfiles repo is
      flake = false;  # it's not a flake, just a source repo
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nix-colors = {
      url = "github:misterio77/nix-colors";
    };
  };

  outputs = { self, nixpkgs, home-manager, nixos-hardware, ... } @ inputs: {
    nixosConfigurations = {

      fw12 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          nixos-hardware.nixosModules."framework-12-13th-gen-intel"
          ./hosts/fw12.nix
          ./modules/common.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.rileytuttle = import ./home/default.nix;
            home-manager.extraSpecialArgs = { inherit inputs; };
          }
        ];
      };

      elitedesk = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/elitedesk.nix
          ./modules/common.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.rileytuttle = import ./home/default.nix;
            home-manager.extraSpecialArgs = { inherit inputs; };
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
