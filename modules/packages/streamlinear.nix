{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      streamlinear = import ../../nix/packages/streamlinear.nix { inherit pkgs; };
    in
    {
      packages.streamlinear = streamlinear;
      checks.streamlinear-build = streamlinear;
    };

  flake.homeModules.streamlinear = import ../home/desktop/services/streamlinear/module.nix {
    inherit self;
  };
}
