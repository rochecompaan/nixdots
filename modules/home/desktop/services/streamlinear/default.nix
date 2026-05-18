{
  config,
  inputs,
  self,
  ...
}:
let
  linearApiTokenPath = config.sops.secrets."linear-api-token".path;
in
{
  imports = [ self.homeModules.streamlinear ];

  sops.secrets."linear-api-token" = {
    sopsFile = "${inputs.nix-secrets}/secrets.yaml";
    path = "${config.home.homeDirectory}/.config/streamlinear/token";
    mode = "0400";
  };

  programs.streamlinear = {
    enable = true;
    tokenFile = linearApiTokenPath;
    mcpSocket.enable = true;
  };
}
