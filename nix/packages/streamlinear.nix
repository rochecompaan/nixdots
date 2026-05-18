{ pkgs }:
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
    chmod -R u+w $out
  '';
in
pkgs.buildNpmPackage {
  pname = "streamlinear";
  inherit version;

  src = streamlinearMcpSrc;
  npmDepsHash = "sha256-4q09wELO1nE2oviJL4oScWXHVVnBTYnly58/Q1K92UA=";
  npmBuildScript = "build";

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/streamlinear $out/bin
    cp -r dist package.json node_modules $out/libexec/streamlinear/

    makeWrapper ${pkgs.nodejs}/bin/node $out/bin/streamlinear \
      --add-flags $out/libexec/streamlinear/dist/index.js

    makeWrapper ${pkgs.nodejs}/bin/node $out/bin/streamlinear-cli \
      --add-flags $out/libexec/streamlinear/dist/cli.js

    runHook postInstall
  '';

  meta = {
    description = "Linear CLI and MCP server from streamlinear";
    homepage = "https://github.com/obra/streamlinear";
    mainProgram = "streamlinear-cli";
  };
}
