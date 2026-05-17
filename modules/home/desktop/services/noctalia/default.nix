{
  config,
  inputs,
  lib,
  ...
}:
let
  settings = (builtins.fromJSON (builtins.readFile ./noctalia.json)).settings;
in
{
  imports = [ inputs.noctalia.homeModules.default ];

  config = lib.mkIf (config.default.de == "niri") {
    programs.noctalia-shell = {
      enable = true;
      settings = lib.mkForce (
        settings
        // {
          idle = settings.idle // {
            enabled = true;
            screenOffTimeout = 1800;
            lockTimeout = 0;
            suspendTimeout = 0;
          };
        }
      );
    };
  };
}
