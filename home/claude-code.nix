# claude-code.nix
{ pkgs, ... }:

{
  home.packages = [ pkgs.claude-code ];

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (pkgs.lib.getName pkg) [ "claude-code" ];

  home.sessionVariables = {
    ANTHROPIC_BASE_URL = "http://localhost:11434";
    ANTHROPIC_AUTH_TOKEN = "ollama";
    ANTHROPIC_API_KEY = "";
  };
}
