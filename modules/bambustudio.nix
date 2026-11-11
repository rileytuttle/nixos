# modules/bambu-studio.nix
{ config, lib, pkgs, ... }:

let
  version = "02.08.00.50"; # bump manually
  pname = "bambu-studio";

  src = pkgs.fetchurl {
    url = "https://github.com/bambulab/BambuStudio/releases/download/v02.08.00.50/BambuStudio_ubuntu24.04-v02.08.00.50-20260625193201.AppImage";
    # nix-prefetch-url <url>  (or nix store prefetch-file)
    sha256 = "1m2d7qws19hsx4vrihx2k08z52q9gzfj84v3bykb9d4kmnwvcv14";
  };

  appimageContents = pkgs.appimageTools.extract {
    inherit pname version src;
  };

  bambu-studio = pkgs.appimageTools.wrapType2 {
    inherit pname version src;
    extraPkgs = pkgs: [ pkgs.webkitgtk_4_1 pkgs.glib-networking ];

    extraInstallCommands = ''
      install -Dm444 ${appimageContents}/*.desktop -t $out/share/applications/
      install -Dm444 ${appimageContents}/*.png -t $out/share/icons/hicolor/256x256/apps/ 2>/dev/null || true
      install -Dm444 ${appimageContents}/*.svg -t $out/share/icons/hicolor/scalable/apps/ 2>/dev/null || true

      substituteInPlace $out/share/applications/*.desktop \
        --replace-fail 'Exec=AppRun' 'Exec=${pname}'

      # The login webview (webkitgtk) needs GIO's TLS backend to do HTTPS;
      # the FHS env doesn't wire GIO_EXTRA_MODULES up on its own, so without
      # this it fails with "TLS support is not available".
      mv $out/bin/${pname} $out/bin/.${pname}-wrapped
      cat > $out/bin/${pname} <<'EOF'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules''${GIO_EXTRA_MODULES:+:}$GIO_EXTRA_MODULES"
exec "$here/.${pname}-wrapped" "$@"
EOF
      chmod +x $out/bin/${pname}
    '';
  };
in
{
  environment.systemPackages = [ bambu-studio ];
}
