{
  time = {
    hardwareClockInLocalTime = true;
  };
  services.tzupdate.enable = true;

  systemd.timers.tzupdate = {
    description = "Update timezone automatically";
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };
}
