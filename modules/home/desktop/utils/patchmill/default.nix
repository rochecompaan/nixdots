{ inputs, pkgs, ... }:
{
  home.packages = [
    inputs.patchmill.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
