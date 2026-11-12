{
  description = "My NixOS config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # Kakoune only -- see modules/kakoune.nix. Same branch as nixpkgs above,
    # locked separately so `nix flake update nixpkgs-kakoune` can chase an
    # editor release without rebuilding the world. Kakoune ships monthly-ish
    # and the kakrc depends on what its rc/ directory provides (the niri
    # windowing module, for one), so it is worth tracking ahead of the system.
    # Fold this back into nixpkgs whenever the main lock catches up.
    nixpkgs-kakoune.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # No kakoune plugin inputs: what fzf.kak, kakoune-sudo-write and
    # openscad.kak used to do is written directly in dotfiles/kakrc, and
    # language support comes from kakoune-lsp (see pkgs/kakoune.nix).

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";  # reuse the same nixpkgs, don't pull a second copy
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

    # rt-dellpromax-24 only -- see home/balena.nix. The balena CLI wrapper used
    # to live in this repo, but colleagues need it on machines that have
    # nothing to do with this config, so it is its own flake now and this is
    # the only copy. `nix flake update balena-plus` after changing it there.
    balena-plus = {
      url = "github:rileytuttle-havoc/balena-plus";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, nixos-hardware, ... } @ inputs:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # claude-code is unfree, and the `pkgs` above is the bare legacyPackages
    # set with no config -- the hosts set nixpkgs.config.allowUnfree inside
    # their own nixpkgs (modules/common.nix), which does nothing for the
    # flake's own `packages` output. This instance exists so
    # packages.claude-container can evaluate. allowUnfree is an eval-time
    # check and nothing else, so the store paths are identical either way.
    pkgsUnfree = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    # Nix only lets a dynamic attribute path like apps.${system} be defined
    # once, so both apps live in one attrset rather than two statements.
    apps.${system} = {
      # `nix run .#refresh-hardware-config` -- re-run the install-time
      # hardware scan and update hosts/<hostname>-hardware-configuration.nix.
      # See scripts/refresh-hardware-config.nix for why this is a command you
      # run rather than something the flake imports on its own.
      refresh-hardware-config = {
        type = "app";
        program = "${import ./scripts/refresh-hardware-config.nix { inherit pkgs; }}/bin/refresh-hardware-config";
        meta.description = "Regenerate hosts/<hostname>-hardware-configuration.nix from the live hardware";
      };

      # `nix run .#xe-engine-util` -- live per-engine GPU busy% from DRM
      # fdinfo, refreshing until Ctrl-C. Leave it up next to nvtop; `--once`
      # for a single sample.
      #
      # An app rather than a devShell package because the one question it
      # answers ("is this transcode actually on the GPU?") comes up while
      # something is already running, and nvtop cannot answer it: its GPU%
      # omits the video engines entirely. See the header of the script, and
      # the nvtop note in the gpu devShell below.
      xe-engine-util = {
        type = "app";
        program = "${import ./scripts/xe-engine-util.nix { inherit pkgs; }}/bin/xe-engine-util";
        meta.description = "Live per-engine GPU busy% from xe DRM fdinfo, including the video engines nvtop omits";
      };
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
        # READ THE DEC COLUMN FOR TRANSCODES, NOT GPU%. nvtop's xe backend
        # (src/extract_gpuinfo_intel_xe.c) builds gpu_usage from
        # drm-cycles-rcs + drm-cycles-ccs only; drm-cycles-vcs goes to a
        # separate decode_usage field shown under DEC, and drm-cycles-vecs
        # is counted toward the cycles total but assigned to no usage field
        # whatsoever. A hevc_qsv job therefore reads GPU% 0 -- measured on
        # fw12 at vcs 99.6% / vecs 53.8% with GPU% showing 0 -- and the
        # VEBOX time that vpp_qsv scaling spends is not visible in any
        # column. Desktop processes do show a GPU% because compositing is
        # render work. `nix run .#xe-engine-util` prints all five engines.
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
                                       GPU% is render+compute ONLY: video
                                       transcodes show under DEC, and the
                                       VEBOX (scaling) engine nowhere.
          nix run .#xe-engine-util     all five engines incl. vecs, live
                                       until Ctrl-C. Optional PID to watch
                                       one process, --once for a single
                                       sample. No devShell needed.
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

    # The scripts carried over from the old Configs repo. Exposed as packages
    # (not just added to home.packages) so they can be reached from any
    # machine with nix: `nix run github:rileytuttle/nixos#shic`.
    packages.${system} = import ./pkgs/scripts.nix { inherit pkgs; } // {
      # `nix run .#claude-container` -- Claude Code in a container that has its
      # own nix and can install tools for itself. See
      # pkgs/claude-container/default.nix; home/claude-container.nix is the
      # home-manager side of the same package.
      #
      # nixpkgsRev is what `nixpkgs#...` resolves to *inside* the container.
      # Passing this flake's own lock means a tool Claude installs in there is
      # the same build the host would have used, and cache.nixos.org already
      # has it.
      claude-container = import ./pkgs/claude-container {
        pkgs = pkgsUnfree;
        nixpkgsRev = nixpkgs.rev;
      };
    };

    # `nix flake check` -- builds every host in one go. This exists because
    # hosts/desktop.nix sat broken for months without anything noticing: it
    # imported a hardware scan that was never committed. A half-finished host
    # now fails here instead of silently.
    checks.${system} = {
      fw12 = self.nixosConfigurations.fw12.config.system.build.toplevel;
      elitedesk = self.nixosConfigurations.elitedesk.config.system.build.toplevel;
      rt-dellpromax-24 = self.homeConfigurations.rt-dellpromax-24.activationPackage;
    };

    # `nix fmt` on this repo. nixfmt 1.4 is the RFC 166 style; the package
    # formerly known as nixfmt-rfc-style is now just `nixfmt`.
    formatter.${system} = pkgs.nixfmt;

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
                ./home/claude-container.nix
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
        # The same portable user environment fw12 and elitedesk get through
        # home/default.nix -- git, bash, the fzf git functions, tmux.conf,
        # the CLI tools. core.nix carries no NixOS dependency and no
        # identity, so a standalone home-manager host can take it directly;
        # hosts/rt-dellpromax-24.nix supplies the host-specific half.
        ./home/core.nix
        ./home/niri.nix
        ./home/dank-material-shell.nix
        ./home/niri-generic-linux.nix
        # Same shared layout fw12 gets from modules/kanata.nix, driven by a
        # systemd *user* service instead of a NixOS one. The uinput/group
        # setup nix cannot do here is in `kanata-host-setup`, which that
        # module puts on PATH -- run it once after the first switch.
        ./home/kanata-generic-linux.nix
        ./home/balena.nix
        ./home/claude-container.nix
      ];
    };
  };
}
