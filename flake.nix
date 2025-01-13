{
  description = "Roché Compaan's NixOS configuration";

  inputs = {
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";

    # Nixpkgs Stable
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Home-manager
    hm.url = "github:nix-community/home-manager/release-24.11";
    hm.inputs.nixpkgs.follows = "nixpkgs";

    # secret management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # nix helper
    nh.url = "github:viperML/nh";
    nh.inputs.nixpkgs.follows = "nixpkgs";

    # Nixos hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Stylix, nix-colors alertnative
    stylix.url = "github:danth/stylix";
    stylix.inputs.nixpkgs.follows = "nixpkgs";

    # Zellij plugin for statusbar
    zjstatus.url = "github:dj95/zjstatus";

    # Anyrun, an app launcher
    anyrun.url = "github:Kirottu/anyrun";
    anyrun.inputs.nixpkgs.follows = "nixpkgs";

    # Ags, a customizable and extensible shell
    ags.url = "github:Aylur/ags";

    # waybar, a customizable wayland bar
    waybar.url = "github:Alexays/Waybar";
    waybar.inputs.nixpkgs.follows = "nixpkgs";

    # Nix User Repository
    nur.url = "github:nix-community/NUR";

    # Hyprland, the modern compositor for wayland
    # hyprland.url = "git+https://github.com/hyprwm/Hyprland?submodules=1";
    # hyprland.inputs.nixpkgs.follows = "nixpkgs";

    # Hyprspacem workspace overview plugin
    hyprspace.url = "github:KZDKM/Hyprspace";
    # hyprspace.inputs.hyprland.follows = "hyprland";

    # Hyprpaper, wallpaper manager for hyprland
    hyprpaper.url = "github:hyprwm/hyprpaper";

    # My personal nixvim config
    nixvim.url = "github:rochecompaan/nixvim";

    # Private repo
    # Authenticate via ssh and use shallow clone
    nix-secrets = {
      url = "git+ssh://git@github.com/rochecompaan/nix-secrets.git?ref=main&shallow=1";
      inputs = { };
    };

  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [
        ./hosts
        ./home
        ./pre-commit-hooks.nix
      ];

      perSystem =
        { config, pkgs, ... }:
        {
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-rfc-style
              pkgs.git
              pkgs.nh
              inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.aider-chat
            ];
            name = "dots";
            DIRENV_LOG_FORMAT = "";
            shellHook = ''
              ${config.pre-commit.installationScript}
            '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
