{ config, pkgs, lib, ... }:

let
  kakoune-rt = pkgs.stdenv.mkDerivation {
    pname = "kakoune";
    version = "HEAD";
    src = pkgs.fetchFromGitHub {
      owner = "rileytuttle";
      repo = "kakoune";
      rev = "rtuttle/main";
      sha256 = "sha256-O92bdCh0FpwqvY0deCzFzAFVnDCKEQg3P5QcnD2Gn/8=";
    };
    nativeBuildInputs = with pkgs; [ gnumake gcc pkg-config ];
    buildInputs = with pkgs; [ ncurses ];
    installPhase = ''
      make PREFIX=$out install
    '';
  };
in
{
  home.packages = [ kakoune-rt ];
  home.sessionVariables.EDITOR = "kak";
  home.file.".config/kak/kakrc".source = ./kakrc;
}
