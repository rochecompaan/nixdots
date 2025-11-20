{ self, inputs, ... }:
{
  flake = {
    nixosConfigurations =
      let
        inherit (inputs.nixpkgs.lib) nixosSystem;
        inherit (import "${self}/modules/nixos") default;

        specialArgs = {
          inherit inputs self;
        };

        mkHost =
          hostname:
          nixosSystem {
            inherit specialArgs;
            modules = default ++ [
              # Provide openziti overlay + modules to all hosts
              inputs.openziti-nix.nixosModules.default
              inputs.disko.nixosModules.disko
              ./${hostname}
            ];
          };
      in
      {
        kiptum = mkHost "kiptum";
        kipchoge = mkHost "kipchoge";
        dauwalter = mkHost "dauwalter";
        kipsang = mkHost "kipsang";
        fordyce = mkHost "fordyce";
        walmsley = mkHost "walmsley";
      };

    # homelab nodes
    deploy.nodes = {
      dauwalter = {
        hostname = "192.168.1.100";
        profiles.system = {
          user = "root";
          sshUser = "roche";
          path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dauwalter;
        };
      };

      kipsang = {
        hostname = "192.168.1.101";
        profiles.system = {
          user = "root";
          sshUser = "roche";
          path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.kipsang;
        };
      };

      fordyce = {
        hostname = "192.168.1.102";
        profiles.system = {
          user = "root";
          sshUser = "roche";
          path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.fordyce;
        };
      };

      walmsley = {
        hostname = "192.168.1.103";
        profiles.system = {
          user = "root";
          sshUser = "roche";
          path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.walmsley;
        };
      };

    };

  };
}
