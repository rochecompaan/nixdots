{
  config,
  inputs,
  lib,
  ...
}:
{
  imports = [ inputs.noctalia.homeModules.default ];

  config = lib.mkIf (config.default.de == "niri") {
    programs.noctalia-shell = {
      enable = true;
      settings = lib.mkForce ((builtins.fromJSON (builtins.readFile ./noctalia.json)).settings);
    };
  };
}
