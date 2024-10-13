{ pkgs, lib, ... }:
{
  console = {
    earlySetup = true;
    font = "${pkgs.terminus_font}/share/consolefonts/ter-132n.psf.gz";
    packages = with pkgs; [ terminus_font ];
    keyMap = lib.mkForce "us-acentos";
    useXkbConfig = true;
  };
}
