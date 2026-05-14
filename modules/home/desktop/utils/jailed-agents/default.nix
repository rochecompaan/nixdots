{
  config,
  inputs,
  pkgs,
  ...
}:
let
  # Import the Roche Pi jailed module with Home Manager's DAG helpers.
  rochePiJailedModule =
    (import "${inputs.roche-pi}/modules/home/jailed-pi.nix" {
      self = inputs.roche-pi;
      lib = inputs.nixpkgs.lib // {
        hm = inputs.hm.lib.hm;
      };
    }).flake.homeModules."jailed-pi";
in
{
  imports = [ rochePiJailedModule ];

  sops.secrets."openrouter-api-key" = {
    sopsFile = "${inputs.nix-secrets}/secrets.yaml";
  };

  programs.roche-pi.jailed = {
    enable = true;
    apiKeys.OPENROUTER_API_KEY.file = config.sops.secrets."openrouter-api-key".path;
    extraPkgs = [ pkgs.neovim ];
  };
}
