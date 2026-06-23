{ lib, ... }:
{
  disko.devices = {
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.0025388581b2f42d";
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

    disk.data = {
      device = lib.mkDefault "/dev/disk/by-id/ata-ST8000DM004-2U9188_ZR16ATHH";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          data = {
            name = "data";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-data";
            };
          };
        };
      };
    };

    lvm_vg."vg-data" = {
      type = "lvm_vg";
      lvs = {
        "srv-data" = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/srv/data";
            mountOptions = [
              "noatime"
            ];
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
