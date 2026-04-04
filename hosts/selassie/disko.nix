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
          root = {
            name = "root";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    disk.data = {
      device = lib.mkDefault "/dev/disk/by-id/ata-ST16000NM001G-2KK103_ZL2FS4RR";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          data = {
            name = "data";
            size = "100%";
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
    };
  };
}
