{ pkgs, ... }:
{
  systemd.user.services."onedrive@onedrive" = {
    Unit = {
      Description = "OneDrive Free Client";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${pkgs.onedrive}/bin/onedrive --monitor";
      Restart = "on-failure";
      RestartSec = "3s";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
