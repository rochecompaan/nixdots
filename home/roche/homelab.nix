{ pkgs, ... }:
{
  imports = [
    ../../modules/home/shell
  ];

  home = {
    username = "roche";
    homeDirectory = "/home/roche";
    stateVersion = "24.05";

    sessionVariables = {
      EDITOR = "nvim";
      PAGER = "less";
      MANPAGER = "nvim +Man!";
      MANWIDTH = "999";
    };

    packages = with pkgs; [
      atuin
      bat
      curl
      eza
      fzf
      git
      gnugrep
      gnupg
      jq
      kubectl
      kubectx
      lazygit
      less
      neovim
      openssh
      starship
      timewarrior
      zoxide
    ];
  };

  programs.home-manager.enable = true;
}
