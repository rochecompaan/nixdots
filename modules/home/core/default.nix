{ config, self, ... }:
{
  wallpaper = "${self}/home/shared/walls/${config.theme}.png";
  home = {
    sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = "foot";
      BROWSER = "firefox";
      MANPAGER = "nvim +Man!";
      MANWIDTH = "999";
    };
    sessionPath = [ "${config.home.homeDirectory}/.krew/bin" ];
  };
  imports = [
    ./gtk.nix
    ./nixpkgs.nix
    ./options.nix
    ./overlays.nix
    ./programs.nix
    ./style/stylix.nix
    ./home.nix
  ];

  programs.home-manager.enable = true;
}
