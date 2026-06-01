{ config, pkgs, ... }:

{
  # Enable OpenSSH server
  services.openssh = {
    enable = true;
    settings = {
      # Disable root login for safety
      PermitRootLogin = "no";
      # Use key-based authentication only
      PasswordAuthentication = true;
    };

    # Optional: change port (default 22)
    # port = 2222;
  };

  # Optional: add a simple firewall rule for SSH (requires nixos-firewall)
  # networking.firewall.allowedTCPPorts = [ 22 ]; # or [ 2222 ] if port changed
}
