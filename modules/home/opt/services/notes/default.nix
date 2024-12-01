{
  systemd.user.services = {
    notes-auto-commit = {
      Unit = {
        Description = "Auto Commit Notes Repository";
        After = [ "network.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "/home/roche/notes/auto-commit.sh";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

  systemd.user.timers = {
    notes-auto-commit = {
      Unit.Description = "Run notes-auto-commit.service every 15 minutes";
      Timer = {
        Unit = "notes-auto-commit";
        OnCalendar = "*:0/15";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
