{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Security/encryption
    sops
    age
    gnupg

    # System tools
    dig
    btop
    killall
    ncdu
    pciutils
    procps
    usbutils
    wirelesstools

    # File operations
    bat
    eza
    ripgrep
    sd
    unzip
    wget

    # Development
    git
    git-extras
    gnu-config
    nix-prefetch-git
    terraform-ls

    # Shell/terminal
    lua54Packages.lua
    python3
    yq
  ];

  nixpkgs.config = {
    allowUnfree = true;
  };
}
