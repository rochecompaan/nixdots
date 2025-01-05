{ pkgs, config, ... }:
{
  environment.systemPackages = with pkgs; [
    sops

    age
    bat
    blender
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

    (
      let
        cura5 = appimageTools.wrapType2 rec {
          name = "cura5";
          version = "5.4.0";
          src = fetchurl {
            url = "https://github.com/Ultimaker/Cura/releases/download/${version}/UltiMaker-Cura-${version}-linux-modern.AppImage";
            hash = "sha256-QVv7Wkfo082PH6n6rpsB79st2xK2+Np9ivBg/PYZd74=";
          };
          extraPkgs = pkgs: with pkgs; [ ];
        };
      in
      writeScriptBin "cura" ''
        #! ${pkgs.bash}/bin/bash
        # AppImage version of Cura loses current working directory and treats all paths relateive to $HOME.
        # So we convert each of the files passed as argument to an absolute path.
        # This fixes use cases like `cd /path/to/my/files; cura mymodel.stl anothermodel.stl`.
        args=()
        for a in "$@"; do
          if [ -e "$a" ]; then
            a="$(realpath "$a")"
          fi
          args+=("$a")
        done
        QT_QPA_PLATFORM=xcb exec "${cura5}/bin/cura5" "''${args[@]}"
      ''
    )

  ];
  nixpkgs.config = {
    allowUnfree = true;
  };
}
