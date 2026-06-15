{
  config,
  inputs,
  lib,
  ...
}:
{
  imports = [ inputs.noctalia.homeModules.default ];

  config = lib.mkIf (config.default.de == "niri") {
    programs.noctalia = {
      enable = true;
      settings = ./noctalia.toml;
    };
  };
}
