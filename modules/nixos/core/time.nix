{
  time = {
    hardwareClockInLocalTime = true;
    timeZone = "Africa/Johannesburg";
  };
  services.tzupdate.enable = false;

  # systemd.timers.tzupdate = {
  #   description = "Update timezone automatically";
  #   timerConfig = {
  #     OnCalendar = "hourly";
  #     Persistent = true;
  #   };
  #   wantedBy = [ "timers.target" ];
  # };
}
