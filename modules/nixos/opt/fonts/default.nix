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

      nerd-fonts.fira-code
      nerd-fonts.zed-mono
      nerd-fonts.iosevka
      nerd-fonts.jetbrains-mono
      nerd-fonts.monaspace
    ];
  };
}
