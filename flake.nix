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
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # rt-dellpromax-24 only. DMS is Quickshell (Qt6/QML) from nix, so on a
    # foreign distro it links nix's libEGL and cannot see Ubuntu's GL driver.
    # See home/niri-generic-linux.nix. fw12 is NixOS and never touches this.
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, nixos-hardware, ... } @ inputs:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # `nix run .#refresh-hardware-config` -- re-run the install-time
    # hardware scan and update hosts/<hostname>-hardware-configuration.nix.
    # See scripts/refresh-hardware-config.nix for why this is a command you
    # run rather than something the flake imports on its own.
    apps.${system}.refresh-hardware-config = {
      type = "app";
      program = "${import ./scripts/refresh-hardware-config.nix { inherit pkgs; }}/bin/refresh-hardware-config";
      meta.description = "Regenerate hosts/<hostname>-hardware-configuration.nix from the live hardware";
    };

    # `nix develop .#gpu` -- the once-in-a-while GPU toolbox. Deliberately
    # not in any host's systemPackages: these get reached for when
    # something looks wrong, not daily.
    #
    # Worth having as a devShell rather than ad-hoc `nix shell nixpkgs#...`
    # for two reasons: it pins the tools to this flake's nixpkgs, so Mesa
    # here matches the Mesa the system is running, and it records which
    # tools actually work on this hardware. That last part is not obvious --
    # see the note on intel_gpu_top below.
    devShells.${system}.gpu = pkgs.mkShell {
      packages = with pkgs; [
        # Live per-process utilization. Reads DRM fdinfo, which is why it
        # works on xe and needs no root.
        #
        # NOT intel-gpu-tools: as of 2.3 intel_gpu_top's engine counters
        # only know the i915 PMU. On this board it finds the card
        # (`intel_gpu_top -L` prints "Intel Pantherlake (Gen30)") and then
        # fails with "Failed to detect engines!" for every -d filter. xe's
        # PMU exists, just under another name:
        # /sys/bus/event_source/devices/xe_0000_00_02.0
        nvtopPackages.intel

        pciutils      # lspci
        libva-utils   # vainfo -- video decode/encode profiles
        vulkan-tools  # vulkaninfo --summary, vkcube
        mesa-demos    # eglinfo, glxinfo; 400+ binaries, hence shell-only

        glmark2       # OpenGL benchmark
        vkmark        # Vulkan benchmark
        clpeak        # OpenCL compute throughput
      ];

      shellHook = ''
        cat <<'EOF'
        GPU toolbox. Measured on fw12 (Core Series 3 / Wildcat Lake, xe):

          nvtop                        live util, per-process, no root
          lspci -nnk | grep -A3 VGA    which driver claimed the GPU
          vainfo                       video decode/encode profiles
          vulkaninfo --summary         Vulkan devices
          eglinfo -B | grep -i render  GL renderer -- "llvmpipe" here means
                                       you are rendering on the CPU
          vkcube --c 100               end-to-end render smoke test

          glmark2-wayland              OpenGL bench      (scored 3317)
          glmark2-wayland --fullscreen  ...at real resolution
          glmark2-wayland --run-forever sustained load, to watch nvtop move
          vkmark                       Vulkan bench      (scored 13946)
          clpeak                       OpenCL   (1251 GFLOPS fp32 / 2485 fp16)
        EOF
      '';
    };

    nixosConfigurations = {

      fw12 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          # Not framework-12-13th-gen-intel: this is the Intel Core Series 3
          # mainboard ("Core 5 320", family 6 model 213), and that module's
          # one distinctive setting -- pinctrl_tigerlake in initrd, to beat
          # soc_button_array to the tablet-mode GPIO -- is dead here. On this
          # board the pinctrl driver is pinctrl_intel_platform, INT33D3:00
          # has no driver bound at all, and orientation comes off the EC
          # (cros-ec-lid-angle in /sys/bus/iio/devices) instead.
          #
          # nixos-hardware has no Framework 12 Core-Series-3 module yet (as of
          # rev 1b418b8, 2026-10-22), so import the generation-neutral 12-inch
          # base by path. That still brings fwupd, framework-laptop-kmod,
          # framework-tool, iio sensors, tlp and the SSD tuning; only the
          # 13th-gen-specific initrd module is dropped.
          (inputs.nixos-hardware + "/framework/12-inch/common")
          (inputs.nixos-hardware + "/common/cpu/intel")
          ./hosts/fw12.nix
          ./modules/common.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            # niri.nix and dank-material-shell.nix are separate, fw12-only
            # home-manager files (not part of home/default.nix) so either
            # one can be dropped from this list on its own if it doesn't
            # work out.
            home-manager.users.rileytuttle = {
              imports = [
                ./home/default.nix
                ./home/niri.nix
                ./home/dank-material-shell.nix
                ./home/claude-code.nix
              ];
            };
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

    # rt-dellpromax-24 is Ubuntu with nix as a plain package manager, not
    # NixOS — hence standalone home-manager rather than a nixosConfiguration.
    # niri itself is built from source into /usr/local by
    # scripts/install-niri-from-source.sh (which also drops the gdm session
    # entry); nix supplies the config plus the userland pieces that
    # modules/niri.nix installs system-wide on fw12. See
    # home/niri-generic-linux.nix.
    homeConfigurations.rt-dellpromax-24 = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        config.allowUnfree = true;
        # Supplies pkgs.nixgl.*, used by home/niri-generic-linux.nix to wrap
        # DMS. Scoped to this host's pkgs, so fw12 is unaffected.
        #
        # Hand-rolled rather than inputs.nixgl.overlay: upstream's overlay
        # reads `final.system`, which trips nixpkgs' "'system' has been
        # renamed to 'stdenv.hostPlatform.system'" eval warning. This is
        # the same thing with the flags spelled out for x86_64-linux.
        overlays = [
          (final: _: {
            nixgl = import "${inputs.nixgl}/default.nix" {
              pkgs = final;
              enable32bits = true;
              enableIntelX86Extensions = true;
            };
          })
        ];
      };
      # dank-material-shell.nix reaches for inputs.dms, so this is required.
      extraSpecialArgs = { inherit inputs; };
      modules = [
        ./hosts/rt-dellpromax-24.nix
        ./home/niri.nix
        ./home/dank-material-shell.nix
        ./home/niri-generic-linux.nix
        ./home/helix.nix
        ./home/balena.nix
      ];
    };
  };
}
