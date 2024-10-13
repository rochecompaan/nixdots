{ self, inputs, ... }:
{
  flake.homeConfigurations =
    let
      inherit (inputs.hm.lib) homeManagerConfiguration;

      extraSpecialArgs = {
        inherit inputs self;
      };
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;

      mkHome =
        hostname:
        homeManagerConfiguration {
          inherit extraSpecialArgs pkgs;
          modules = [ ./roche/${hostname}.nix ];
        };
    in
    {
      "roche@kiptum" = mkHome "kiptum";
      "roche@kipchoge" = mkHome "kipchoge";
    };
}
