{
  description = "Roché Compaan's NixOS configuration";

  inputs = {
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";

    # Nixpkgs Stable
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Home-manager
    hm.url = "github:nix-community/home-manager/release-25.05";
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
    stylix.url = "github:danth/stylix/release-25.05";
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

    krewfile = {
      url = "github:brumhard/krewfile";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko.url = "github:nix-community/disko";

    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs.url = "github:serokell/deploy-rs";
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
              pkgs.deploy-rs
              pkgs.nixfmt-rfc-style
              pkgs.git
              pkgs.nh
              pkgs.nixos-anywhere
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
