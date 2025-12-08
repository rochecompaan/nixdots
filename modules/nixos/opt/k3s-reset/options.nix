{ lib, ... }:
with lib;
{
  options.homelab.k3s.reset.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Disable k3s and delete k3s/cluster data during activation.";
  };
}
