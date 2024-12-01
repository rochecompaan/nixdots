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

      nerd-fonts.firaCode
      nerd-fonts.fantasqueSansMono
      nerd-fonts.zedMono 
      nerd-fonts.iosevka
      nerd-fonts.jetbrainsMono
      nerd-fonts.monaspace
    ];
  };
}
