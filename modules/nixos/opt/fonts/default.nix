{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf config.fonts.enable {
    fonts.packages = with pkgs; [
      # icon fonts
      material-design-icons
      noto-fonts-emoji

      # normal fonts
      rubik
      lexend
      noto-fonts
      roboto
      liberation_ttf

      (nerdfonts.override {
        fonts = [
          "FiraCode"
          "FantasqueSansMono"
          "ZedMono"
          "Iosevka"
          "JetBrainsMono"
          "Monaspace"
        ];
      })
    ];
  };
}
