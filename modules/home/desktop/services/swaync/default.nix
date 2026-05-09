#              ╭──────────────────────────────────────────────────╮
#              │             CREDITS TO: @khaneliman              │
#              │ THIS IS A FORK OF HIS CONFIG, ALL CREDITS TO HIM │
#              ╰──────────────────────────────────────────────────╯
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dependencies =
    with pkgs;
    [
      bash
      coreutils
      grim
      hyprpicker
      jq
      libnotify
      slurp
      wl-clipboard
    ]
    ++ lib.optionals (config.default.de == "hyprland") [
      config.wayland.windowManager.hyprland.package
    ];

  settings = import ./settings.nix { inherit lib pkgs; };
  style = import ./style.nix { inherit config; };
in
{
  services.swaync = {
    enable = lib.mkForce false;
    package = pkgs.swaynotificationcenter;

    inherit settings;
    inherit (style) style;
  };

  systemd.user.services.swaync.Service.Environment = lib.mkIf config.services.swaync.enable (
    "PATH=/run/wrappers/bin:${lib.makeBinPath dependencies}"
  );
}
