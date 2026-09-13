{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.services.copyparty-mount.enable = lib.mkEnableOption "the Copyparty WebDAV mount";

  config = lib.mkIf config.services.copyparty-mount.enable {
    environment.systemPackages = with pkgs; [
      fuse3
      rclone
    ];

    sops.secrets.copyparty = {
      owner = "roche";
      group = "users";
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d /home/roche/mnt 0755 roche users - -"
      "d /home/roche/mnt/copyparty 0755 roche users - -"
    ];

    systemd.services.rclone-copyparty = {
      description = "Mount Copyparty WebDAV";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment.PATH = lib.mkForce "/run/wrappers/bin:${lib.makeBinPath [ pkgs.fuse3 ]}";

      script = ''
        password="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.copyparty.path})"
        obscured_password="$(${pkgs.rclone}/bin/rclone obscure "$password")"

        umask 077
        ${pkgs.coreutils}/bin/cat > "$RUNTIME_DIRECTORY/rclone.conf" <<EOF
        [copyparty]
        type = webdav
        url = https://copyparty.compaan
        vendor = owncloud
        pacer_min_sleep = 0.01ms
        user = k
        pass = $obscured_password
        EOF

        exec ${pkgs.rclone}/bin/rclone mount copyparty: /home/roche/mnt/copyparty \
          --config "$RUNTIME_DIRECTORY/rclone.conf" \
          --disable-http2 \
          --transfers 1 \
          --max-connections 1 \
          --vfs-cache-mode writes \
          --dir-cache-time 5s \
          --cache-dir "$CACHE_DIRECTORY"
      '';

      serviceConfig = {
        User = "roche";
        Group = "users";
        CacheDirectory = "rclone-copyparty";
        CacheDirectoryMode = "0700";
        RuntimeDirectory = "rclone-copyparty";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStop = "/run/wrappers/bin/fusermount3 -u /home/roche/mnt/copyparty";
      };
    };
  };
}
