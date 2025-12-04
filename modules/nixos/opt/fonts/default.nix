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
      noto-fonts-color-emoji

      # normal fonts
      rubik
      lexend
      noto-fonts
      roboto
      liberation_ttf

      nerd-fonts.fantasque-sans-mono
      nerd-fonts.fira-code
      nerd-fonts.iosevka
      nerd-fonts.jetbrains-mono
      nerd-fonts.monaspace
      nerd-fonts.zed-mono

    ];
  };
}
