{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.storage.linstor;
in
{
  options.homelab.storage.linstor = {
    enable = lib.mkEnableOption "LINSTOR/Piraeus host prerequisites";

    nodeLabel.enable = lib.mkEnableOption "the k3s LINSTOR benchmark node label";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.extraModprobeConfig = ''
          options drbd usermode_helper=disabled
        '';
        boot.extraModulePackages = [ config.boot.kernelPackages.drbd ];
        boot.initrd.services.lvm.enable = true;
        boot.kernelModules = [ "drbd" ];

        environment.systemPackages = [
          pkgs.drbd
          pkgs.lvm2
        ];
      }

      (lib.mkIf cfg.nodeLabel.enable {
        services.k3s.extraFlags = lib.mkAfter [
          "--node-label=storage.compaan.io/linstor-benchmark=true"
        ];
      })
    ]
  );
}
