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
    programs.noctalia = {
      enable = true;
      settings = lib.mkForce (
        settings
        // {
          idle = settings.idle // {
            enabled = true;
            screenOffTimeout = 1800;
            # 0 disables the Noctalia lock monitor; keep this aligned so the
            # session is locked and requires PAM authentication when DPMS turns off.
            lockTimeout = 1800;
            suspendTimeout = 0;
          };
        }
      );
    };
  };
}
