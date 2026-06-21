{ lib, ... }:
{
  disko.devices = {
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.2c3ebffff000277a";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          lvm = {
            name = "lvm";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-nvme";
            };
          };
        };
      };
    };

    lvm_vg."vg-nvme" = {
      type = "lvm_vg";
      lvs = {
        "linstor-bench-thin" = {
          size = "30G";
          lvm_type = "thin-pool";
        };
        "mayastor-bench" = {
          size = "30G";
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
