{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf config.modules.gpg-agent.enable {
    services.gpg-agent = {
      enable = true;
      enableSshSupport = true;
      defaultCacheTtl = 3600;
      pinentry.package = pkgs.pinentry-gtk2;
    };
  };
}
