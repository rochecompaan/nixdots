{ config, self, ... }:
{
  wallpaper = "${self}/home/shared/walls/${config.theme}.jpg";
  home.sessionVariables.EDITOR = "nvim";
  home.sessionVariables.TERMINAL = "kitty";
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
