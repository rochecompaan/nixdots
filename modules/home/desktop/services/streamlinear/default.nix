{
  config,
  inputs,
  pkgs,
  ...
}:
let
  version = "unstable-2026-02-16";

  streamlinearSrc = pkgs.fetchFromGitHub {
    owner = "obra";
    repo = "streamlinear";
    rev = "ee5982c9b35ee94e0be9d27f43cdcc8902a40bca";
    hash = "sha256-UpKg176GWb1PafX/iq5SJ/wgPo+DX+8TQexooOo2fyU=";
  };

  streamlinearMcpSrc = pkgs.runCommand "streamlinear-mcp-src" { } ''
    cp -r ${streamlinearSrc}/mcp $out
  '';

  streamlinearBase = pkgs.buildNpmPackage {
    pname = "streamlinear-mcp";
    inherit version;
    src = streamlinearMcpSrc;
    npmDepsHash = "sha256-4q09wELO1nE2oviJL4oScWXHVVnBTYnly58/Q1K92UA=";
    npmBuildScript = "build";
    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/libexec/streamlinear $out/bin
      cp -r dist package.json node_modules $out/libexec/streamlinear/

      makeWrapper ${pkgs.nodejs}/bin/node $out/bin/streamlinear-raw \
        --add-flags $out/libexec/streamlinear/dist/index.js

      makeWrapper ${pkgs.nodejs}/bin/node $out/bin/streamlinear-cli-raw \
        --add-flags $out/libexec/streamlinear/dist/cli.js

      runHook postInstall
    '';
  };

  linearApiTokenPath = config.sops.secrets."linear-api-token".path;

  tokenLoader = ''
    token_file=${linearApiTokenPath}
    if [ -z "''${LINEAR_API_TOKEN:-}" ] && [ -r "$token_file" ]; then
      export LINEAR_API_TOKEN="$(tr -d '\r\n' < "$token_file")"
    fi
  '';

  streamlinearWrappers = pkgs.symlinkJoin {
    name = "streamlinear-tools-${version}";
    paths = [ streamlinearBase ];
  };

  streamlinear = pkgs.writeShellScriptBin "streamlinear" ''
    set -euo pipefail
    ${tokenLoader}
    exec ${streamlinearBase}/bin/streamlinear-raw "$@"
  '';

  streamlinearCli = pkgs.writeShellScriptBin "streamlinear-cli" ''
    set -euo pipefail
    ${tokenLoader}
    exec ${streamlinearBase}/bin/streamlinear-cli-raw "$@"
  '';

  streamlinearMcpClient = pkgs.writeShellScriptBin "streamlinear-mcp-client" ''
    set -euo pipefail
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    exec ${pkgs.socat}/bin/socat STDIO UNIX-CONNECT:"$runtime_dir/streamlinear/mcp.sock"
  '';

  streamlinearPackage = pkgs.symlinkJoin {
    name = "streamlinear-package-${version}";
    paths = [
      streamlinearWrappers
      streamlinear
      streamlinearCli
      streamlinearMcpClient
    ];
  };
in
{
  sops.secrets."linear-api-token" = {
    sopsFile = "${inputs.nix-secrets}/secrets.yaml";
    path = "${config.home.homeDirectory}/.config/streamlinear/token";
    mode = "0400";
  };

  home.packages = [ streamlinearPackage ];

  home.file.".config/streamlinear/README.md".text = ''
    # streamlinear

    linear-api-token is managed by sops-nix and written to:

      ${linearApiTokenPath}

    The local wrappers automatically read this file when LINEAR_API_TOKEN
    is not already set in the environment.

    Installed commands:

    - streamlinear-cli        # direct CLI for search/get/update/comment/create/graphql
    - streamlinear            # stdio MCP server wrapper
    - streamlinear-mcp-client # connect to the user socket-activated MCP service

    User systemd units:

    - streamlinear-mcp.socket
    - streamlinear-mcp@.service
  '';

  systemd.user.sockets.streamlinear-mcp = {
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

  systemd.user.services."streamlinear-mcp@" = {
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
}
