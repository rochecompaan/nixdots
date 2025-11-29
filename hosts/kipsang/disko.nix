{ lib, ... }:
{
  disko.devices = {
    # System NVMe (by-id for stability)
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.2c3ebffff000290a";
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

    # 16TB SATA data disk
    disk.data = {
      device = lib.mkDefault "/dev/disk/by-id/wwn-0x5000c500c961abb2";
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
                "nofail"
              ];
            };
          };
        };
      };
    };
  };
}
