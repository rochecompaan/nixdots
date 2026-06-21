{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.storage.mayastor;
in
{
  options.homelab.storage.mayastor = {
    enable = lib.mkEnableOption "Mayastor host prerequisites";

    enableMultipath = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NVMe native multipath for Mayastor NVMe-oF paths.";
    };

    hugepages2MiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
      description = "Number of 2 MiB hugepages reserved for Mayastor io-engine.";
    };

    nodeLabel.enable = lib.mkEnableOption "the k3s Mayastor io-engine node label";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.initrd.services.lvm.enable = true;
        boot.kernelModules = [ "nvme_tcp" ];
        boot.kernelParams = [
          "default_hugepagesz=2M"
          "hugepagesz=2M"
          "hugepages=${toString cfg.hugepages2MiB}"
        ]
        ++ lib.optionals cfg.enableMultipath [
          "nvme_core.multipath=Y"
        ];
        boot.supportedFilesystems = [ "xfs" ];
      }

      (lib.mkIf cfg.nodeLabel.enable {
        services.k3s.extraFlags = lib.mkAfter [
          "--node-label=openebs.io/engine=mayastor"
        ];
      })
    ]
  );
}
