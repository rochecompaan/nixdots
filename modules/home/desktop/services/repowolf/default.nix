{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.repowolf;
  policy = import ./policy.nix;
  supportedHosts = [
    "kipchoge"
    "kiptum"
  ];

  configPath = "${config.xdg.configHome}/repowolf/repowolf.yaml";
  certificatePath = "${config.xdg.configHome}/repowolf/tls/tls.crt";
  privateKeyPath = "${config.xdg.configHome}/repowolf/tls/tls.key";
  providerSecret = "repowolf/providers/github/token";
  privateKeySecret = "repowolf/tls/${cfg.hostName}/private-key";
  tokenSecret = principal: "repowolf/tokens/${cfg.hostName}/${principal}";

  yaml = pkgs.formats.yaml { };
  generatedConfig = yaml.generate "repowolf.yaml" {
    apiVersion = "repowolf.dev/v1alpha1";
    listen = "172.17.0.1:8443";
    tls = {
      certificate = certificatePath;
      privateKey = privateKeyPath;
    };
    tools = {
      gh = "${pkgs.gh}/bin/gh";
      ssh = "${pkgs.openssh}/bin/ssh";
    };
    inherit (policy) providers principals repositories;
  };

  tokenSecrets = builtins.listToAttrs (
    map (principal: {
      name = tokenSecret principal;
      value.sopsFile = "${inputs.nix-secrets}/secrets.yaml";
    }) policy.principalIds
  );

  environmentContent =
    lib.concatStringsSep "\n" (
      [ "GH_TOKEN=${config.sops.placeholder.${providerSecret}}" ]
      ++ map (
        principal:
        "${policy.tokenEnvironments.${principal}}=${config.sops.placeholder.${tokenSecret principal}}"
      ) policy.principalIds
    )
    + "\n";

  sshAuthSock =
    if cfg.sshAuthSock == null then
      ''"$(${pkgs.gnupg}/bin/gpgconf --list-dirs agent-ssh-socket)"''
    else
      lib.escapeShellArg cfg.sshAuthSock;

  launcher = pkgs.writeShellScript "repowolf-service" ''
    set -euo pipefail
    export SSH_AUTH_SOCK=${sshAuthSock}
    ${cfg.package}/bin/repowolf config validate --config ${lib.escapeShellArg configPath}
    exec ${cfg.package}/bin/repowolf serve --config ${lib.escapeShellArg configPath}
  '';
in
{
  options.services.repowolf = {
    enable = mkEnableOption "the RepoWolf repository access broker";

    hostName = mkOption {
      type = types.str;
      default = "";
      description = "Host name used to select RepoWolf TLS and token secrets.";
    };

    package = mkOption {
      type = types.package;
      default = inputs.repowolf.packages.${pkgs.system}.repowolf;
      defaultText = lib.literalExpression "inputs.repowolf.packages.${pkgs.system}.repowolf";
      description = "RepoWolf service and administration package.";
    };

    sshAuthSock = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional SSH-agent socket override. Null selects the GPG SSH-agent socket.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem cfg.hostName supportedHosts;
        message = "services.repowolf.hostName must be kipchoge or kiptum";
      }
      {
        assertion = cfg.sshAuthSock == null || cfg.sshAuthSock != "";
        message = "services.repowolf.sshAuthSock must be null or a non-empty path";
      }
    ];

    sops.secrets = tokenSecrets // {
      ${providerSecret}.sopsFile = "${inputs.nix-secrets}/secrets.yaml";
      ${privateKeySecret} = {
        sopsFile = "${inputs.nix-secrets}/secrets.yaml";
        path = privateKeyPath;
        mode = "0400";
      };
    };

    sops.templates."repowolf-service.env" = {
      content = environmentContent;
      mode = "0400";
    };

    xdg.configFile = {
      "repowolf/repowolf.yaml".source = generatedConfig;
      "repowolf/tls/ca.crt".source = ./tls/${cfg.hostName}-ca.crt;
      "repowolf/tls/tls.crt".source = ./tls/${cfg.hostName}.crt;
    };

    home.packages = [ cfg.package ];

    systemd.user.services.repowolf = {
      Unit = {
        After = [ "sops-nix.service" ];
        Description = "RepoWolf repository access broker";
        PartOf = [ "sops-nix.service" ];
        X-Restart-Triggers = [
          generatedConfig
          "${./tls/${cfg.hostName}.crt}"
        ];
      };
      Service = {
        EnvironmentFile = config.sops.templates."repowolf-service.env".path;
        ExecStart = launcher;
        NoNewPrivileges = true;
        PrivateTmp = false;
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
