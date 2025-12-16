{ pkgs, ... }:
{
  virtualisation = {
    libvirtd.enable = true;
    docker = {
      enable = true;
      daemon = {
        settings = {
          runtimes = {
            nvidia = {
              path = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
              runtimeArgs = [ ];
            };
          };
        };
      };
    };
  };

  environment.systemPackages = [ pkgs.nvidia-container-toolkit ];
}
