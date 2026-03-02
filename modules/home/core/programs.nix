{ pkgs, ... }:
{
  programs = {
    direnv = {
      silent = false;
      enable = true;
      enableBashIntegration = true; # see note on other shells below
      nix-direnv.enable = true;
    };
    bash.enable = true;
    krewfile = {
      enable = true;
      krewPackage = pkgs.krew;
      plugins = [
        "cert-manager"
        "view-secret"
        "cnpg"
        "minio"
        "node-shell"
        "oidc-login"
        "rook-ceph"
      ];
    };
  };
}
