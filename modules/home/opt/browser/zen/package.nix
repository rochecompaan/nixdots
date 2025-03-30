{
  appimageTools,
  fetchurl,
  lib,
  ...
}:

let
  pname = "zen-browser";
  version = "latest";

  src = fetchurl {
    url = "https://github.com/zen-browser/desktop/releases/latest/download/zen-x86_64.AppImage";
    sha256 = "sha256-1NoDIdzeADVLOhtesR0QZefhAdRBSNWg4++MjqdkfIs=";
  };

  appimageContents = appimageTools.extract {
    inherit pname version src;
  };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    # Install .desktop file
    install -m 444 -D ${appimageContents}/zen.desktop $out/share/applications/${pname}.desktop
    # Install icon
    install -m 444 -D ${appimageContents}/zen.png $out/share/icons/hicolor/128x128/apps/${pname}.png

    # Update desktop file
    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace 'Exec=AppRun' 'Exec=${pname}'
  '';

  meta = with lib; {
    description = "Experience tranquillity while browsing the web without people tracking you";
    homepage = "https://zen-browser.app/";
    license = licenses.mpl20;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
  };
}
