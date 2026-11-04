{ config, pkgs, lib, ... }:

# Movement and mode-switching keys ported from dotfiles/kakrc/kakrc.
let
  # Rendered markdown preview in a new terminal window (helix can't render
  # markdown itself). Reads the file from disk, so save first to see edits.
  # gnome-terminal comes from PATH: on non-NixOS hosts the system one works,
  # a nix-built one would need nixGL.
  open-markdown-with-glow = pkgs.writeShellScriptBin "open-markdown-with-glow" ''
    file=$(realpath "$1")
    gnome-terminal --title="glow: $(basename "$file")" -- ${pkgs.glow}/bin/glow -p "$file"
  '';
in
{
  home.packages = [ open-markdown-with-glow ];

  programs.helix = {
    enable = true;

    # Language servers/formatters, on hx's PATH only. `hx --health <lang>`
    # shows what helix finds.
    extraPackages = with pkgs; [
      nil                  # nix
      nixfmt               # nix formatter
      basedpyright         # python
      ruff                 # python lint + format
      clang-tools          # clangd for c/c++
      bash-language-server # bash; picks up shellcheck/shfmt from PATH
      shellcheck
      shfmt
      # ansible-language-server was dropped from nixpkgs (2025-09); ansible
      # yaml gets schema validation from yaml-language-server's SchemaStore.
      yaml-language-server
      marksman             # markdown: links, headings, completion (no formatting)
      prettier             # markdown formatter
    ];

    languages = {
      language-server = {
        basedpyright = { command = "basedpyright-langserver"; args = [ "--stdio" ]; };
        ruff = { command = "ruff"; args = [ "server" ]; };
      };
      # auto-format = format on save
      language = [
        { name = "nix"; language-servers = [ "nil" ]; formatter.command = "nixfmt"; auto-format = true; }
        { name = "python"; language-servers = [ "basedpyright" "ruff" ]; auto-format = true; }
        { name = "c"; auto-format = true; }
        { name = "cpp"; auto-format = true; }
        { name = "bash"; auto-format = true; }
        { name = "yaml"; auto-format = true; }
        {
          name = "markdown";
          language-servers = [ "marksman" ];
          formatter = { command = "prettier"; args = [ "--parser" "markdown" ]; };
          auto-format = true;
        }
      ];
    };

    settings = {
      keys.insert = {
        # jk / jK / Jk / JK -> normal mode
        j = { k = "normal_mode"; K = "normal_mode"; };
        J = { k = "normal_mode"; K = "normal_mode"; };
      };

      keys.normal = {
        # word motions moved from b to q
        q = "move_prev_word_start";
        Q = "extend_prev_word_start";
        "A-q" = "move_prev_long_word_start";
        "A-Q" = "extend_prev_long_word_start";

        # macros move off q to ^ (replay) and alt-^ (record)
        "^" = "replay_macro";
        "A-^" = "record_macro";

        # x already extends line-wise in helix; X trims to full lines (kak <a-X>)
        X = "shrink_to_line_bounds";

        # , = keep main selection and <space> = leader are already helix defaults

        # space m = preview current buffer with glow in a new window
        space.m = ":sh open-markdown-with-glow %{buffer_name}";
      };
    };
  };
}
