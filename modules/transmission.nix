# modules/transmission.nix
{
  config,
  pkgs,
  lib,
  ...
}:

{
  # The RPC interface is deliberately loopback-only. It used to bind
  # 0.0.0.0 with the whitelist disabled, which was worse than it looked:
  # modules/tailscale.nix:10 puts tailscale0 in
  # networking.firewall.trustedInterfaces, and a trusted interface bypasses
  # the firewall entirely -- so the whole tailnet could reach the daemon no
  # matter what allowedTCPPorts said. Binding to loopback is the only thing
  # that actually closes that; the firewall cannot.
  #
  # Reaching the web UI is unaffected: modules/local-nginx.nix proxies
  # 127.0.0.1:80 ("transmission-local") -> 127.0.0.1:9091, and nginx itself
  # listens only on loopback, so both ends stay local. From another machine,
  # tunnel it:  ssh -N -L 9091:127.0.0.1:9091 fw12
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;

    user = "rileytuttle";
    group = "users";

    settings = {
      # rpc-bind-address is intentionally absent: nixpkgs already defaults
      # it to 127.0.0.1, so the safe value is the one you get by not
      # setting it. Likewise rpc-whitelist-enabled, whose default is on.
      rpc-authentication-required = true;
      rpc-username = "rileytuttle";
      # FIXME: rotate this. The previous value was committed to this repo,
      # which is public on GitHub, so it is burned and lives on in git
      # history regardless of what this line says now. Once the daemon is
      # loopback-only the password only guards against other local users,
      # but a value that is published is not a password.
      #
      # To keep it out of the (world-readable) Nix store entirely, use
      # services.transmission.credentialsFile -- a JSON file merged at
      # runtime, e.g. {"rpc-password":"..."} at an absolute path outside
      # the repo. Do NOT pass a Nix path literal (./secrets/foo.json):
      # the option is types.path, so that would copy the plaintext into
      # the store.
      rpc-password = "rileytuttle";
      rpc-port = 9091;

      download-dir = "/home/rileytuttle/transmission/";
      incomplete-dir = "/home/rileytuttle/transmission/.incomplete";
      incomplete-dir-enabled = true;

      peer-port = 51413;
      utp-enabled = true;
    };
    # downloadDirPermissions = "0775";
  };

  # # let your user actually access files the daemon owns
  # users.users.rileytuttle.extraGroups = [ "transmission" ];

  # Open the peer port only. The RPC port is no longer opened: dropping
  # `openRPCPort = true` removes the allowedTCPPorts entry it used to add
  # (it does nothing else), and there is nothing to open once RPC is on
  # loopback.
  networking.firewall.allowedTCPPorts = [ 51413 ];
  networking.firewall.allowedUDPPorts = [ 51413 ];
}
