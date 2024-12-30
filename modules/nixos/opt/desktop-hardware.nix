{ config, lib, ... }:

let
  cfg = config.desktop;
in
{
  options.desktop = {
    enable = lib.mkEnableOption "Desktop hardware configuration";
  };

  config = lib.mkIf cfg.enable {
    hardware = {
      bluetooth.enable = true;
      bluetooth.input.General = {
        ClassicBondedOnly = false;
      };
      bluetooth.powerOnBoot = true;
      graphics = {
        enable = true;
        enable32Bit = true;
      };
      gpgSmartcards.enable = true;
      ledger.enable = true;
      nvidia.open = false;
      nvidia.powerManagement = {
        enable = true;
        finegrained = true;
      };
      keyboard.qmk.enable = true;
    };
  };
}
