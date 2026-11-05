# claude-container -- Claude Code in a container that can install its own tools.
#
# Two pieces:
#
#   image    an OCI image built by nix (dockerTools.streamLayeredImage), with
#            claude-code, a small userland, and *nix itself* inside.
#   wrapper  `claude-container`, which loads that image on first use and then
#            runs it over the directory you are standing in.
#
# WHY NIX INSIDE A NIX-BUILT IMAGE. The image ships `includeNixDB = true`, so
# /nix/var/nix/db is populated and the store in the image is a real, valid
# store rather than a pile of files nix refuses to acknowledge. That is what
# lets Claude run `nix profile install nixpkgs#ripgrep` for itself instead of
# asking you to rebuild the image every time it wants a tool. The wrapper
# keeps /nix on a named volume, so those installs survive the container.
#
# WHY THE STORE IS WRITABLE AT ALL. A rootless runtime (podman, or rootless
# docker) maps container uid 0 to your host uid, so the container runs as root,
# owns /nix, and still writes workspace files as you. Under a rootful daemon
# that does not hold, and the entrypoint drops to your uid instead -- see
# entrypoint.sh. Both paths end with a store the container can write to.
#
# The flake exposes this as `packages.claude-container`; home/claude-container.nix
# wraps it as a home-manager module.
{
  pkgs,
  # Rev that `nixpkgs#...` resolves to inside the container. Pass the flake's
  # own `inputs.nixpkgs.rev` so the container builds against the same nixpkgs
  # the host runs -- cache.nixos.org then already has what it asks for, and a
  # tool Claude installs is the tool you would have got outside. Left null it
  # tracks nixos-unstable, which still works but is not pinned to anything.
  nixpkgsRev ? null,
}:
let
  inherit (pkgs) lib;

  # Where the container's HOME lives *inside* the container. Not /root: the
  # entrypoint may run as a non-root uid under a rootful daemon, and a HOME
  # that moves depending on the runtime would move ~/.claude with it.
  containerHome = "/home/claude";

  # PATH inside the container. `nix profile` installs come first so a tool
  # Claude installs for itself beats the one baked into the image; /bin is the
  # symlink farm dockerTools builds from `contents` below.
  containerPath = lib.concatStringsSep ":" [
    "${containerHome}/.local/state/nix/profile/bin" # nix >= 2.14 `nix profile`
    "${containerHome}/.nix-profile/bin" # the compat symlink it also keeps
    "/nix/var/nix/profiles/default/bin"
    "/bin"
    "/usr/bin"
  ];

  # ---- /etc, written by hand ----------------------------------------------
  #
  # These are real files in the image's own layer rather than contributions
  # from `contents`, because symlinkJoin turns a path only one package
  # provides into a symlink into the (read-only) store, and three things here
  # need /etc to be writable: the entrypoint appends a passwd entry, and the
  # runtime bind-mounts /etc/hosts and /etc/resolv.conf over ours at startup.

  nixConf = pkgs.writeText "nix.conf" ''
    experimental-features = nix-command flakes

    # Single-user nix: there is no daemon in here and no build-users group, so
    # builds run as whoever the entrypoint settled on.
    build-users-group =

    # The build sandbox needs to create user namespaces, which a container
    # generally cannot nest (and rootless podman definitely cannot). Almost
    # everything Claude installs comes straight from the cache, so this only
    # costs purity on the rare path that actually builds.
    sandbox = false
    filter-syscalls = false

    # Resolve flake refs from the file below instead of fetching the global
    # registry over the network. `nixpkgs` is pinned there; other bare ids
    # will not resolve, which is deliberate -- spell those out as full refs.
    flake-registry = /etc/nix/registry.json
  '';

  registryJson = pkgs.writeText "registry.json" (
    builtins.toJSON {
      version = 2;
      flakes = [
        {
          from = {
            type = "indirect";
            id = "nixpkgs";
          };
          to = {
            type = "github";
            owner = "NixOS";
            repo = "nixpkgs";
          }
          // (if nixpkgsRev == null then { ref = "nixos-unstable"; } else { rev = nixpkgsRev; });
        }
      ];
    }
  );

  # root plus nobody is all the image needs; the entrypoint appends an entry
  # for the caller's uid when it has to run as one.
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:${containerHome}:/bin/bash
    nobody:x:65534:65534:nobody:/var/empty:/bin/sh
  '';
  groupFile = pkgs.writeText "group" ''
    root:x:0:
    nogroup:x:65534:
  '';
  nsswitchFile = pkgs.writeText "nsswitch.conf" ''
    hosts: files dns
    passwd: files
    group: files
  '';

  # ---- the entrypoint -----------------------------------------------------
  entrypoint = pkgs.writeShellApplication {
    name = "claude-container-entrypoint";
    runtimeInputs = with pkgs; [
      coreutils # chown, cat, id
      gnugrep
      util-linux # setpriv
    ];
    # CC_PATH is how the entrypoint puts the container's PATH back: this
    # writer prepends runtimeInputs to PATH, and that prefix would otherwise
    # be inherited by claude and shadow ~/.nix-profile.
    text = ''
      cc_path=${lib.escapeShellArg containerPath}
    ''
    + builtins.readFile ./entrypoint.sh;
  };

  # ---- the image ----------------------------------------------------------
  contents = with pkgs; [
    # The reason this exists.
    claude-code

    # The reason it stays useful: a package manager of its own.
    nix
    cacert

    # Enough userland for claude's Bash tool to be worth having.
    bashInteractive
    coreutils
    findutils
    diffutils
    gnugrep
    gnused
    gawk
    gnutar
    gzip
    xz
    less
    procps
    util-linux
    which
    curl
    git
    openssh # git over ssh, with --ssh-agent
    ripgrep
    jq
  ];

  # Tag and volume name are derived from what actually went into the image, so
  # bumping claude-code (or editing anything above) gives a new tag the wrapper
  # notices is missing and loads, and a new /nix volume rather than an old
  # store shadowing the new image's one. `--prune` clears the leftovers.
  buildHash = builtins.substring 0 8 (
    builtins.hashString "sha256" (
      lib.concatStringsSep ":" (
        map toString (
          contents
          ++ [
            entrypoint
            nixConf
            registryJson
            passwdFile
            groupFile
            nsswitchFile
          ]
        )
      )
    )
  );

  imageName = "claude-container";
  imageTag = "${pkgs.claude-code.version}-${buildHash}";

  image = pkgs.dockerTools.streamLayeredImage {
    name = imageName;
    tag = imageTag;
    inherit contents;

    # Registers the closure of `contents` in /nix/var/nix/db and roots it in
    # /nix/var/nix/gcroots/docker, so a `nix-collect-garbage` inside the
    # container cannot delete claude out from under itself.
    includeNixDB = true;

    # Give the store paths room to spread across layers: the next claude-code
    # bump then re-pushes one layer's worth rather than the whole image.
    maxLayers = 110;

    extraCommands = ''
      rm -rf etc
      mkdir -p etc/nix etc/ssl/certs tmp usr/bin root ${lib.removePrefix "/" containerHome}

      cp ${nixConf} etc/nix/nix.conf
      cp ${registryJson} etc/nix/registry.json
      cp ${passwdFile} etc/passwd
      cp ${groupFile} etc/group
      cp ${nsswitchFile} etc/nsswitch.conf
      cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-bundle.crt
      ln -s ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      chmod 0644 etc/nix/nix.conf etc/nix/registry.json etc/passwd etc/group \
                 etc/nsswitch.conf etc/ssl/certs/ca-bundle.crt

      ln -s /bin/env usr/bin/env
      chmod 1777 tmp
    '';

    config = {
      Entrypoint = [ "${entrypoint}/bin/claude-container-entrypoint" ];
      Cmd = [ "claude" ];
      WorkingDir = containerHome;
      Env = [
        "PATH=${containerPath}"
        "CC_PATH=${containerPath}"
        "HOME=${containerHome}"
        "USER=claude"
        "LANG=C.UTF-8"
        "TMPDIR=/tmp"
        "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
        # It is a nix install; there is nothing for the updater to write to.
        "DISABLE_AUTOUPDATER=1"
        "IS_SANDBOX=1"
      ];
    };
  };

  # ---- the wrapper --------------------------------------------------------
  #
  # PATH note, same shape as pkgs/scripts.nix: podman and docker are
  # deliberately absent from runtimeInputs. The container runtime is a
  # system-level thing (a daemon socket, or setuid newuidmap) that has to be
  # the host's own, not a copy from this flake's store.
  wrapper = pkgs.writeShellApplication {
    name = "claude-container";
    runtimeInputs = with pkgs; [
      coreutils # realpath, id, mkdir, install
      gnugrep
      ncurses # tput, for the warnings
    ];
    text = ''
      # Generated preamble -- pkgs/claude-container/default.nix injects these.
      image_streamer=${image}
      image_name=${imageName}
      image_ref=${imageName}:${imageTag}
      nix_volume=claude-container-nix-${buildHash}
      container_home=${containerHome}
      default_home="''${XDG_DATA_HOME:-$HOME/.local/share}/claude-container/home"
    ''
    + builtins.readFile ./claude-container.sh;

    meta.description = "Run Claude Code in a container with its own writable nix store";
  };
in
wrapper.overrideAttrs (old: {
  # Reachable as `claude-container.image` for `nix build .#claude-container.image`
  # when you want the tarball-streaming script by itself.
  passthru = (old.passthru or { }) // {
    inherit image imageName imageTag;
    imageRef = "${imageName}:${imageTag}";
  };
})
