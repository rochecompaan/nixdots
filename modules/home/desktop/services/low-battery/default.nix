{
  config,
  lib,
  pkgs,
  ...
}:
let
  checker = pkgs.writeShellScript "low-battery-alert" ''
    #!/usr/bin/env bash
    set -eu

    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
    state_dir="$runtime_dir/low-battery-alert"
    state_file="$state_dir/notified"

    ${pkgs.coreutils}/bin/mkdir -p "$state_dir"

    minutes_from_human_time() {
      local value unit
      value="$1"
      unit="$2"

      case "$unit" in
      hour|hours)
        ${pkgs.gawk}/bin/awk -v v="$value" 'BEGIN { printf "%d\n", int((v * 60) + 0.5) }'
        ;;
      minute|minutes)
        ${pkgs.gawk}/bin/awk -v v="$value" 'BEGIN { printf "%d\n", int(v + 0.5) }'
        ;;
      second|seconds)
        echo 1
        ;;
      *)
        echo ""
        ;;
      esac
    }

    warned=0

    while true; do
      on_battery=0
      best_minutes=""

      while IFS= read -r battery; do
        [ -n "$battery" ] || continue

        info="$(${pkgs.upower}/bin/upower -i "$battery")"
        state="$(printf '%s\n' "$info" | ${pkgs.gawk}/bin/awk -F': *' '/^[[:space:]]*state:/ { print $2; exit }')"

        [ "$state" = "discharging" ] || continue
        on_battery=1

        time_line="$(printf '%s\n' "$info" | ${pkgs.gawk}/bin/awk -F': *' '/^[[:space:]]*time to empty:/ { print $2; exit }')"
        [ -n "$time_line" ] || continue

        value="$(printf '%s\n' "$time_line" | ${pkgs.gawk}/bin/awk '{ print $1 }')"
        unit="$(printf '%s\n' "$time_line" | ${pkgs.gawk}/bin/awk '{ print $2 }')"
        [ -n "$value" ] && [ -n "$unit" ] || continue

        minutes="$(minutes_from_human_time "$value" "$unit")"
        [ -n "$minutes" ] || continue

        if [ -z "$best_minutes" ] || [ "$minutes" -lt "$best_minutes" ]; then
          best_minutes="$minutes"
        fi
      done < <(${pkgs.upower}/bin/upower -e | ${pkgs.gawk}/bin/awk '/\/battery(_|$)/ { print }')

      if [ "$on_battery" -eq 1 ] && [ -n "$best_minutes" ] && [ "$best_minutes" -le 5 ]; then
        if [ "$warned" -eq 0 ]; then
          ${pkgs.libnotify}/bin/notify-send \
            -u critical \
            -a "Battery Alert" \
            -i battery-caution-symbolic \
            "Low Battery" \
            "Estimated battery remaining: ''${best_minutes} minute(s)."
          ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i bell-terminal -d "low-battery-alert" || true
          warned=1
          : > "$state_file"
        fi
      else
        warned=0
        ${pkgs.coreutils}/bin/rm -f "$state_file"
      fi

      ${pkgs.coreutils}/bin/sleep 30
    done
  '';
in
{
  options.lowBatteryAlert.enable = lib.mkEnableOption "low battery alert at 5 minutes remaining";

  config = lib.mkIf (config.default.isDesktop && config.lowBatteryAlert.enable) {
    systemd.user.services.low-battery-alert = {
      Unit = {
        Description = "Low battery alert (5 minutes remaining)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${checker}";
        Restart = "always";
        RestartSec = 5;
      };

      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
