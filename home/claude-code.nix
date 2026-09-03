# claude-code.nix
{ pkgs, ... }:

{
  home.packages = [ pkgs.claude-code ];

  home.sessionVariables = {
    ANTHROPIC_BASE_URL = "http://agx-orin:11434";
    ANTHROPIC_AUTH_TOKEN = "ollama";
    ANTHROPIC_API_KEY = "";
  };
}
