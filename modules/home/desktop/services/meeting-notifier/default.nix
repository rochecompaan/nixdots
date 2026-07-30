{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.meetingNotifier;
  validDuration = value: builtins.match "^[1-9][0-9]*(s|m|h)$" value != null;
  validHost = value: builtins.match "^([*][.])?[A-Za-z0-9][A-Za-z0-9.-]*$" value != null;

  firefoxLauncher = pkgs.callPackage ../../wayland/niri/firefox-launcher/package.nix {
    firefox = config.programs.firefox.package;
    inherit (pkgs) niri;
  };
  jsonFormat = pkgs.formats.json { };
  configFile = jsonFormat.generate "meeting-notifier-config.json" {
    inherit (cfg)
      accounts
      allowedHosts
      horizon
      leadTime
      pollInterval
      workspace
      ;
    browserBin = lib.getExe' pkgs.xdg-utils "xdg-open";
    firefoxLauncherBin = lib.getExe firefoxLauncher;
    systemctlBin = lib.getExe' pkgs.systemd "systemctl";
  };
in
{
  options.services.meetingNotifier = {
    enable = lib.mkEnableOption "actionable Google Calendar meeting notifications";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      description = "Meeting notifier package.";
    };
    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
    };
    leadTime = lib.mkOption {
      type = lib.types.str;
      default = "5m";
    };
    horizon = lib.mkOption {
      type = lib.types.str;
      default = "24h";
    };
    workspace = lib.mkOption {
      type = lib.types.str;
      default = "5";
    };
    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "meet.google.com"
        "zoom.us"
        "*.zoom.us"
      ];
    };
    accounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.firefoxProfile = lib.mkOption {
            type = lib.types.str;
            description = "Existing Firefox profile used for this account label.";
          };
        }
      );
      default = { };
    };
  };

  config = lib.mkIf (config.default.isDesktop && cfg.enable) {
    assertions = [
      {
        assertion = config.default.de == "niri";
        message = "services.meetingNotifier requires the Niri desktop environment.";
      }
      {
        assertion = cfg.accounts != { };
        message = "services.meetingNotifier.accounts must not be empty.";
      }
      {
        assertion = lib.all (account: account.firefoxProfile != "") (lib.attrValues cfg.accounts);
        message = "Every meeting notifier account must have a non-empty Firefox profile.";
      }
      {
        assertion = lib.all validDuration [
          cfg.pollInterval
          cfg.leadTime
          cfg.horizon
        ];
        message = "Meeting notifier durations must be positive integer seconds, minutes, or hours.";
      }
      {
        assertion = lib.all validHost cfg.allowedHosts;
        message = "Every meeting notifier allowed host must be a valid host pattern.";
      }
    ];

    home.packages = [ cfg.package ];

    xdg.configFile."meeting-notifier/config.json".source = configFile;

    systemd.user.services.meeting-notifier = {
      Unit = {
        Description = "Google Calendar meeting notifier";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        X-Restart-Triggers = [ "${configFile}" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} run";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
