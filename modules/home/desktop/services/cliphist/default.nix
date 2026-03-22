{
  lib,
  pkgs,
  ...
}:
let
  mkCliphistService = description: mimeType: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type ${mimeType} --watch ${lib.getBin pkgs.cliphist}/cliphist store";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
in
{
  systemd.user.services = {
    cliphist = mkCliphistService "Clipboard history (text)" "text";
    cliphist-images = mkCliphistService "Clipboard history (image)" "image";
  };
}
