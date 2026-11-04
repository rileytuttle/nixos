# A Tdarr transcode node for the server running on the Unraid box (mahi).
#
# Deliberately *not* services.tdarr from nixpkgs: that packages tdarr 2.86.01
# and the server is on 3.01.00. Node and server versions have to match, so this
# runs the upstream image at a pinned tag instead. The compose file and the
# launcher script are both generated from here, so this file is the one place
# to edit.
#
# Nothing starts on its own. `tdarr-node up` runs the preflight checks and
# starts the container; away from home the server is unreachable and it refuses
# to start rather than sitting in a retry loop.
#
# One-time manual setup, because these are secrets and the Nix store is
# world-readable:
#
#   sudo install -d -m 0750 -o root -g docker /etc/nixos-secrets
#
#   sudo install -m 0600 -o root -g root /dev/null /etc/nixos-secrets/smb-mahi.cred
#   sudo tee /etc/nixos-secrets/smb-mahi.cred >/dev/null <<'EOF'
#   username=tdarr
#   password=...
#   EOF
#
#   # 0640 root:docker, not 0600: `docker compose` reads env_file as the
#   # invoking user. Being in the docker group is already root-equivalent, so
#   # this grants nothing that membership didn't already.
#   sudo install -m 0640 -o root -g docker /dev/null /etc/nixos-secrets/tdarr-node.env
#   sudo tee /etc/nixos-secrets/tdarr-node.env >/dev/null <<'EOF'
#   apiKey=tapi_...
#   EOF

{ config, pkgs, lib, ... }:

let
  ###########################################################################
  # Tunables -- everything you are likely to change lives in this block.
  ###########################################################################

  serverIP   = "192.168.1.12";
  serverPort = 8266;
  serverURL  = "http://${serverIP}:${toString serverPort}";

  # The node runs its own API that the *server* polls, so this has to be open
  # in the firewall (see networking.firewall below).
  nodeAPIPort = 8267;

  nodeName = "fw12";

  # MUST equal the server's version. Check it with:
  #   curl -s http://192.168.1.12:8266/api/v2/status
  # A mismatched node either refuses to register or misbehaves subtly.
  imageTag = "3.01.00";

  # Paths as the *server container* sees them. A mapped node has to present the
  # same files at the same paths -- match these and no path translators are
  # needed at all. Read them off the Tdarr UI: Libraries -> source folder, and
  # Libraries -> transcode cache folder.
  serverMediaPath = "/mnt/media";
  serverCachePath = "/temp";

  # Where those two live on this machine.
  shareMount = "/mnt/mahi/starr_media";
  mediaDir   = "${shareMount}/media";
  localCache = "/var/cache/tdarr";   # transcode scratch, local NVMe on purpose
  stateDir   = "/var/lib/tdarr-node";

  # The container runs as this uid/gid and the CIFS mount presents files as it.
  # Keep the two in step or the node can read the share but not write to it.
  puid = 1000;   # rileytuttle
  pgid = 100;    # users

  # Belt and braces for /dev/dri. renderD128 is already world-rw on this host,
  # so this mostly guards against a future udev rule tightening it.
  #
  # Hardware encoding is confirmed working, which was the open question when
  # this was written -- Wildcat Lake is new enough that the image's ffmpeg
  # could easily have been too old for it. It isn't: the image ships
  # jellyfin-ffmpeg 7.1.4 with iHD 26.2.2, which knows this chip, and both
  # hevc_vaapi and hevc_qsv encode against /dev/dri/renderD128. Re-test after
  # an image bump with:
  #
  #   docker run --rm --device /dev/dri:/dev/dri \
  #     --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg haveagitgat/tdarr_node:TAG \
  #     -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va \
  #     -f lavfi -i testsrc=size=1280x720:rate=30:duration=3 \
  #     -vf 'format=nv12,hwupload' -c:v hevc_vaapi -f null -
  renderGid = config.users.groups.render.gid;

  smbCredFile = "/etc/nixos-secrets/smb-mahi.cred";
  nodeEnvFile = "/etc/nixos-secrets/tdarr-node.env";
  composeFile = "/etc/tdarr-node/docker-compose.yml";

  # systemd's name for the CIFS mount, used in the script's error message.
  mountUnit = (lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" shareMount)) + ".mount";
in
{
  ###########################################################################
  # The media share
  ###########################################################################

  # noauto + x-systemd.automount is the roaming guard for the mount: away from
  # home this never hangs boot or wedges shutdown, it just stays unmounted.
  fileSystems.${shareMount} = {
    device = "//${serverIP}/starr_media";
    fsType = "cifs";
    options = [
      "credentials=${smbCredFile}"
      "uid=${toString puid}"
      "gid=${toString pgid}"
      "file_mode=0664"
      "dir_mode=0775"
      "vers=3.1.1"
      "iocharset=utf8"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=10s"
      "_netdev"
      "nofail"
    ];
  };

  ###########################################################################
  # Scratch + state
  ###########################################################################

  systemd.tmpfiles.rules = [
    "d /etc/nixos-secrets 0750 root docker -"
    "d ${stateDir}         0755 ${toString puid} ${toString pgid} -"
    "d ${stateDir}/configs 0755 ${toString puid} ${toString pgid} -"
    "d ${stateDir}/logs    0755 ${toString puid} ${toString pgid} -"
    "d ${localCache}       0755 ${toString puid} ${toString pgid} -"
  ];

  ###########################################################################
  # The compose file
  ###########################################################################

  # restart: "no" is what keeps this from coming back on boot or after a
  # docker daemon restart. It runs when, and only when, you ask it to.
  environment.etc."tdarr-node/docker-compose.yml".text = ''
    services:
      tdarr-node:
        image: haveagitgat/tdarr_node:${imageTag}
        container_name: tdarr-node
        network_mode: host
        restart: "no"
        env_file:
          - ${nodeEnvFile}
        environment:
          - serverIP=${serverIP}
          - serverPort=${toString serverPort}
          - nodeName=${nodeName}
          - nodeType=mapped
          - inContainer=true
          - PUID=${toString puid}
          - PGID=${toString pgid}
          # Register idle. Raise workers in the UI when you want a job to run;
          # this is what makes "queue everything, transcode exactly one" work.
          #
          # Raise the *GPU* transcode worker, not the CPU one, if you want
          # hardware encoding: the Community encoder plugin gates its whole
          # hardware branch on args.workerType.includes('gpu'), so a job on a
          # CPU worker silently falls back to libx265 however the flow is
          # configured.
          - startPaused=true
          - transcodecpuWorkers=0
          - transcodegpuWorkers=0
          - healthcheckcpuWorkers=0
          - healthcheckgpuWorkers=0
        devices:
          - /dev/dri:/dev/dri
        group_add:
          - "${toString renderGid}"
        volumes:
          - ${stateDir}/configs:/app/configs
          - ${stateDir}/logs:/app/logs
          - ${localCache}:${serverCachePath}
          - ${mediaDir}:${serverMediaPath}
  '';

  ###########################################################################
  # The launcher
  ###########################################################################

  environment.systemPackages = [
    pkgs.cifs-utils
    (pkgs.writeShellApplication {
      name = "tdarr-node";
      runtimeInputs = with pkgs; [ docker curl util-linux coreutils ];
      text = ''
        compose=${composeFile}
        server=${serverURL}
        share=${shareMount}

        die() { printf 'tdarr-node: %s\n' "$*" >&2; exit 1; }
        note() { printf 'tdarr-node: %s\n' "$*" >&2; }

        preflight() {
          # The roaming guard. Checked first because it is the common case and
          # the cheapest to test.
          curl -fsS --max-time 5 "$server/api/v2/status" >/dev/null 2>&1 \
            || die "Tdarr server at $server is not reachable -- are you home and on the LAN?"

          [ -r ${nodeEnvFile} ] \
            || die "cannot read ${nodeEnvFile} (needs to exist, mode 0640 root:docker, holding apiKey=...)"

          # An idle x-systemd.automount point looks like an *empty directory*,
          # not an error. A mapped node aimed at an empty directory fails every
          # job with unhelpful messages, so poke the automount and then insist
          # it actually mounted.
          ls "$share" >/dev/null 2>&1 || true
          mountpoint -q "$share" \
            || die "$share is not mounted -- check ${smbCredFile}, then: systemctl status ${mountUnit}"

          [ -e /dev/dri/renderD128 ] \
            || note "warning: /dev/dri/renderD128 is missing, QSV encoding will not work"
        }

        case "''${1:-}" in
          up)
            preflight
            docker compose -f "$compose" -p tdarr-node up -d
            note "started. It registers paused with 0 workers -- raise them in the Tdarr UI."
            ;;
          down)
            docker compose -f "$compose" -p tdarr-node down
            ;;
          logs)
            docker compose -f "$compose" -p tdarr-node logs -f
            ;;
          status)
            docker compose -f "$compose" -p tdarr-node ps
            ;;
          check)
            preflight
            note "preflight OK"
            ;;
          *)
            die "usage: tdarr-node {up|down|logs|status|check}"
            ;;
        esac
      '';
    })
  ];

  ###########################################################################
  # Firewall
  ###########################################################################

  # The server polls the node's API; with network_mode: host that lands here.
  networking.firewall.allowedTCPPorts = [ nodeAPIPort ];
}
