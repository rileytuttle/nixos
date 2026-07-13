# remote-backup.nix
#
# NixOS module: periodically rsyncs directories from a remote server to this
# machine, plus a separate checksum "verify" pass that only reports
# discrepancies (never transfers), so you can tell whether drift happened
# server-side or backup-side.
#
# Usage (in configuration.nix):
#
#   imports = [ ./remote-backup.nix ];
#
#   services.remoteBackup = {
#     enable = true;
#     remoteHost = "main-server.lan";
#     remoteUser = "backup";
#     sshKeyFile = "/root/.ssh/id_backup";
#
#     # Optional: point notifications wherever you like (ntfy, webhook, mail...)
#     notifyScript = pkgs.writeShellScript "notify" ''
#       ${pkgs.curl}/bin/curl -s -H "Title: $1" -d "$2" https://ntfy.sh/your-topic-here
#     '';
#
#     jobs = {
#       # Deterministic placement: bypass the mergerfs pool, write straight
#       # to one physical branch.
#       documents = {
#         source      = "/srv/documents";
#         destination = "/mnt/disk1/backup/documents";
#       };
#
#       # Let mergerfs' create policy decide which drive this lands on.
#       photos = {
#         source      = "/srv/photos";
#         destination = "/mnt/storage/backup/photos";
#         schedule    = "hourly";
#       };
#     };
#   };
#
# Adding another folder later is just another attribute under `jobs`.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.remoteBackup;

  sshOpts = "-i ${cfg.sshKeyFile} -o StrictHostKeyChecking=accept-new -o BatchMode=yes";

  # --- sync job: fast, mtime+size based, actually transfers data ---
  mkSyncScript = name: job:
    pkgs.writeShellScript "backup-${name}.sh" ''
      set -uo pipefail
      LOG="$(mktemp)"
      trap 'rm -f "$LOG"' EXIT

      mkdir -p "${job.destination}"

      ${pkgs.rsync}/bin/rsync -az --delete --delete-excluded \
        --partial --partial-dir=.rsync-partial \
        --itemize-changes --info=progress2 \
        ${concatStringsSep " " job.extraRsyncArgs} \
        -e "${pkgs.openssh}/bin/ssh ${sshOpts}" \
        "${cfg.remoteUser}@${cfg.remoteHost}:${job.source}/" \
        "${job.destination}/" \
        2>&1 | tee "$LOG"
      RC=''${PIPESTATUS[0]}

      if [ "$RC" -ne 0 ]; then
        ${cfg.notifyScript} "Backup FAILED: ${name}" "$(cat "$LOG")"
        exit "$RC"
      elif [ -s "$LOG" ]; then
        echo "Synced changes for ${name}:"
        cat "$LOG"
      fi
    '';

  # --- verify job: slow, full checksum, dry-run only, never transfers ---
  mkVerifyScript = name: job:
    pkgs.writeShellScript "verify-backup-${name}.sh" ''
      set -uo pipefail
      LOG="$(mktemp)"
      trap 'rm -f "$LOG"' EXIT

      ${pkgs.rsync}/bin/rsync -aczn --delete --checksum \
        --itemize-changes --info=progress2 \
        ${concatStringsSep " " job.extraRsyncArgs} \
        -e "${pkgs.openssh}/bin/ssh ${sshOpts}" \
        "${cfg.remoteUser}@${cfg.remoteHost}:${job.source}/" \
        "${job.destination}/" \
        2>&1 | tee "$LOG"
      RC=''${PIPESTATUS[0]}

      if [ "$RC" -ne 0 ]; then
        ${cfg.notifyScript} "Verify FAILED: ${name}" "$(cat "$LOG")"
        exit "$RC"
      elif [ -s "$LOG" ]; then
        ${cfg.notifyScript} "Backup DISCREPANCY: ${name}" "$(cat "$LOG")"
      fi
    '';

  jobService = name: job: {
    "backup-${name}" = {
      description = "Backup ${name} from ${cfg.remoteHost}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mkSyncScript name job}";
      };
    };
    "verify-backup-${name}" = {
      description = "Verify backup ${name} against ${cfg.remoteHost} (checksum, no transfer)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mkVerifyScript name job}";
      };
    };
  };

  jobTimer = name: job: {
    "backup-${name}" = {
      description = "Timer: backup ${name}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = job.schedule;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
    "verify-backup-${name}" = {
      description = "Timer: verify backup ${name}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = job.verifySchedule;
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };
  };

  jobOpts = types.submodule {
    options = {
      source = mkOption {
        type = types.str;
        description = "Absolute path on the remote host to back up.";
        example = "/srv/documents";
      };
      destination = mkOption {
        type = types.str;
        description = ''
          Absolute local path to write into. Point this at a specific
          mergerfs branch (e.g. /mnt/disk1/backup/foo) for deterministic
          drive placement, or at the pooled mergerfs mount
          (e.g. /mnt/storage/backup/foo) to let mergerfs' create policy
          choose the drive.
        '';
      };
      schedule = mkOption {
        type = types.str;
        default = "daily";
        description = "systemd OnCalendar expression for the actual sync.";
      };
      verifySchedule = mkOption {
        type = types.str;
        default = "weekly";
        description = "systemd OnCalendar expression for the checksum-only verify pass.";
      };
      extraRsyncArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "--exclude=.cache" ];
        description = "Extra arguments passed to both the sync and verify rsync invocations.";
      };
    };
  };

in {
  options.services.remoteBackup = {
    enable = mkEnableOption "periodic rsync backups from a remote host";

    remoteHost = mkOption {
      type = types.str;
      description = "Hostname or IP of the server being backed up.";
    };

    remoteUser = mkOption {
      type = types.str;
      default = "backup";
      description = "SSH user on the remote host.";
    };

    sshKeyFile = mkOption {
      type = types.path;
      description = "Private key used to SSH into the remote host.";
    };

    notifyScript = mkOption {
      type = types.path;
      description = ''
        Executable invoked as `notifyScript "<title>" "<body>"` whenever a
        sync fails, a verify fails, or a verify finds discrepancies.
        Defaults to just logging via systemd; override with e.g. an
        ntfy/webhook/mail script.
      '';
      default = pkgs.writeShellScript "remote-backup-notify-default" ''
        echo "[remote-backup] $1: $2" >&2
      '';
    };

    jobs = mkOption {
      type = types.attrsOf jobOpts;
      default = { };
      description = "One entry per directory to back up.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services = mkMerge (mapAttrsToList jobService cfg.jobs);
    systemd.timers = mkMerge (mapAttrsToList jobTimer cfg.jobs);
  };
}
