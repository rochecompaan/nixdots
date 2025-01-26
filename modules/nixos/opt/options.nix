{ lib, ... }:
{
  options = {
    pipewire.enable = lib.mkEnableOption "Enable pipewire";
    wayland.enable = lib.mkEnableOption "Enable wayland";
    fonts.enable = lib.mkEnableOption "Enable fonts";
  };
}
