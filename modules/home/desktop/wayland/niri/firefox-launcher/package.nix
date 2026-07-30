{
  buildGoModule,
  firefox,
  lib,
  makeWrapper,
  niri,
}:
buildGoModule {
  pname = "niri-firefox-launcher";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  nativeBuildInputs = [ makeWrapper ];
  subPackages = [ "cmd/niri-firefox-launcher" ];

  postInstall = ''
    wrapProgram "$out/bin/niri-firefox-launcher" \
      --set FIREFOX_BIN ${lib.getExe firefox} \
      --set NIRI_BIN ${lib.getExe niri}
  '';

  meta = {
    mainProgram = "niri-firefox-launcher";
    platforms = lib.platforms.linux;
  };
}
