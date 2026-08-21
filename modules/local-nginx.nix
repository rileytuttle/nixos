{ config, pkgs, ... }:

let
  # Define your mappings here: alias = "hostname:port";
  proxyMap = {
    "transmission-local" = "127.0.0.1:9091";
  };
in
{
  networking.extraHosts = ''
    ${builtins.concatStringsSep "\n"
      (map (alias: "127.0.0.1 ${alias}") (builtins.attrNames proxyMap))}
  '';

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    virtualHosts = builtins.mapAttrs (alias: target: {
      listen = [ { addr = "127.0.0.1"; port = 80; } ];
      locations."/" = {
        proxyPass = "http://${target}";
        proxyWebsockets = true;
      };
    }) proxyMap;
  };

  # Optional: open firewall if you need access from other machines on your LAN
  # networking.firewall.allowedTCPPorts = [ 80 ];
}
