{ inputs, self, ... }:
{
  imports = [
    inputs.hm.nixosModules.home-manager
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = {
      inherit inputs self;
    };
    users.roche = import ../../../../home/roche/homelab.nix;
  };
}
