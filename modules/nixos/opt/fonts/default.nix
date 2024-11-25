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
      fira-code-symbols
      material-design-icons
      noto-fonts-emoji

      # normal fonts
      rubik
      lexend
      noto-fonts
      roboto
      liberation_ttf
      fira-code

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
