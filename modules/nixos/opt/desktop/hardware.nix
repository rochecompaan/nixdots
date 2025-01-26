{ config, lib, ... }:
let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    hardware = {
      bluetooth = {
        enable = true;
        input.General.ClassicBondedOnly = false;
        powerOnBoot = true;
      };
      graphics = {
        enable = true;
        enable32Bit = true;
      };
      gpgSmartcards.enable = true;
      ledger.enable = true;
      nvidia = {
        open = false;
        powerManagement = {
          enable = true;
          finegrained = true;
        };
      };
      keyboard.qmk.enable = true;
    };
  };
}
