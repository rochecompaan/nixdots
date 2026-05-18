{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    hasPrefix
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;

  cfg = config.programs.streamlinear;

  tokenLoader = optionalString (cfg.tokenFile != null) ''
    token_file=${lib.escapeShellArg cfg.tokenFile}
    if [ -z "''${LINEAR_API_TOKEN:-}" ] && [ -r "$token_file" ]; then
      export LINEAR_API_TOKEN="$(tr -d '\r\n' < "$token_file")"
    fi
  '';

  streamlinear = pkgs.writeShellScriptBin "streamlinear" ''
    set -euo pipefail
    ${tokenLoader}
    exec ${cfg.package}/bin/streamlinear "$@"
  '';

  streamlinearCli = pkgs.writeShellScriptBin "streamlinear-cli" ''
    set -euo pipefail
    ${tokenLoader}
    exec ${cfg.package}/bin/streamlinear-cli "$@"
  '';

  streamlinearMcpClient = pkgs.writeShellScriptBin "streamlinear-mcp-client" ''
    set -euo pipefail
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    exec ${pkgs.socat}/bin/socat STDIO UNIX-CONNECT:"$runtime_dir/streamlinear/mcp.sock"
  '';

  streamlinearPackage = pkgs.symlinkJoin {
    name = "streamlinear-home-${cfg.package.version or "unknown"}";
    paths = [
      streamlinear
      streamlinearCli
      streamlinearMcpClient
    ];
  };
in
{
  options.programs.streamlinear = {
    enable = mkEnableOption "Streamlinear CLI and MCP Home Manager integration";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.system}.streamlinear;
      description = "Raw Streamlinear package to wrap for this Home Manager profile.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path to a Linear API token file used by local wrappers when LINEAR_API_TOKEN is unset.";
    };

    mcpSocket.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable the socket-activated Streamlinear MCP user service.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile == null || hasPrefix "/" cfg.tokenFile;
        message = "programs.streamlinear.tokenFile must be null or an absolute path.";
      }
    ];

    home.packages = [ streamlinearPackage ];

    home.file.".config/streamlinear/README.md".text = ''
      # streamlinear

      The raw package is configured as:

        ${cfg.package}

      Local wrappers load LINEAR_API_TOKEN from:

        ${if cfg.tokenFile == null then "no token file configured" else cfg.tokenFile}

      LINEAR_API_TOKEN from the environment takes precedence over the token file.

      Installed commands:

      - streamlinear-cli        # direct CLI for search/get/update/comment/create/graphql
      - streamlinear            # stdio MCP server wrapper
      - streamlinear-mcp-client # connect to the user socket-activated MCP service

      User systemd units:

      - streamlinear-mcp.socket
      - streamlinear-mcp@.service
    '';

    systemd.user.sockets.streamlinear-mcp = mkIf cfg.mcpSocket.enable {
      Unit.Description = "streamlinear MCP socket";
      Socket = {
        ListenStream = "%t/streamlinear/mcp.sock";
        SocketMode = "0600";
        DirectoryMode = "0700";
        Accept = true;
        RemoveOnStop = true;
      };
      Install.WantedBy = [ "sockets.target" ];
    };

    systemd.user.services."streamlinear-mcp@" = mkIf cfg.mcpSocket.enable {
      Unit.Description = "streamlinear MCP server";
      Service = {
        Type = "simple";
        ExecStart = "${streamlinearPackage}/bin/streamlinear";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        Restart = "no";
      };
    };
  };
}
