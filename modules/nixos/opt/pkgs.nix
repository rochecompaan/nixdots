{ pkgs, config, ... }:
{
  environment.systemPackages = with pkgs; [
    sops

    age
    bat
    blueman
    brightnessctl
    btop
    dig
    dosis
    eza
    ffmpeg_7-full
    git
    git-extras
    gnu-config
    gnupg
    grim
    gtk3
    home-manager
    hyprland
    kanata
    killall
    (lib.mkIf config.tailscale.enable tailscale)
    (lib.mkIf config.wayland.enable wayland)
    lua54Packages.lua
    mpv
    ncdu
    nix-prefetch-git
    nodejs
    obs-studio
    openvpn3
    pamixer
    pass
    pciutils
    procps
    pulseaudio
    python3
    ripgrep
    sd
    slack
    slack-term
    slop
    spotify
    srt
    terraform-ls
    unzip
    usbutils
    wget
    wirelesstools
    xdg-utils
    yaml-language-server
    yq
    yubico-piv-tool
    yubikey-manager
    yubikey-personalization

  ];
  nixpkgs.config = {
    allowUnfree = true;
  };
}
