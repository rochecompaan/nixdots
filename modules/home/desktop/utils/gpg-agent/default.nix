{
  pkgs,
  ...
}:
{
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    defaultCacheTtl = 3600;
    pinentry.package = pkgs.pinentry-gtk2;
  };
}
