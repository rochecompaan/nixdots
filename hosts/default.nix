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
              inputs.disko.nixosModules.disko
              ./${hostname}
            ];
          };
      in
      {
        kiptum = mkHost "kiptum";
        kipchoge = mkHost "kipchoge";
        dauwalter = mkHost "dauwalter";
      };

    # homelab nodes
    deploy.nodes = [
      {
        name = "dauwalter";
        value = {
          hostname = "192.168.1.100";
          profiles.system = {
            user = "root";
            sshUser = "nix";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dauwalter;
          };
        };
      }
      {
        name = "kiptum";
        value = {
          hostname = "192.168.1.101";
          profiles.system = {
            user = "root";
            sshUser = "nix";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dauwalter;
          };
        };
      }
      {
        name = "fordyce";
        value = {
          hostname = "192.168.1.102";
          profiles.system = {
            user = "root";
            sshUser = "nix";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dauwalter;
          };
        };
      }
      {
        name = "walmsley";
        value = {
          hostname = "192.168.1.103";
          profiles.system = {
            user = "root";
            sshUser = "nix";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dauwalter;
          };
        };
      }
    ];
  };
}
