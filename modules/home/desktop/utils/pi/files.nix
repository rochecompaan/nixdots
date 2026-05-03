{ config, pkgs }:
let
  # Pi package derivations
  notionCli = import ./notion-cli.nix { inherit pkgs; };

  piListenSrc = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@codexstar/pi-listen/-/pi-listen-7.2.2.tgz";
    hash = "sha256-MbYQiwQMvXkN0dRYdMTTX+4whLjey/yGcke5zq6BRO0=";
  };

  sherpaOnnxNode = pkgs.fetchzip {
    url = "https://registry.npmjs.org/sherpa-onnx-node/-/sherpa-onnx-node-1.13.0.tgz";
    hash = "sha256-YV+px436CmhSDmshUmOLWTaeoqp+miY69TqHJpMwPkA=";
  };

  sherpaOnnxLinuxX64 = pkgs.fetchzip {
    url = "https://registry.npmjs.org/sherpa-onnx-linux-x64/-/sherpa-onnx-linux-x64-1.13.0.tgz";
    hash = "sha256-w1SfJmebP8inl1z/sd0qaC1wL/KYDmnzD/NiDCde3gY=";
  };

  piListen = pkgs.runCommand "pi-listen-7.2.2" { } ''
    mkdir -p $out/node_modules
    cp -r ${piListenSrc}/. $out/
    cp -r ${sherpaOnnxNode} $out/node_modules/sherpa-onnx-node
    cp -r ${sherpaOnnxLinuxX64} $out/node_modules/sherpa-onnx-linux-x64
  '';

  piSubagentsSrc = pkgs.fetchgit {
    url = "https://github.com/nicobailon/pi-subagents.git";
    rev = "0b3f5b4d16557228cf7ce3e2de7b708f94ccf9ac";
    sha256 = "sha256-OOepzpERAz1E7yIl85IxcXs+QFUzi6uhpC6RjQXr1Yc=";
  };

  piSubagents = pkgs.buildNpmPackage {
    pname = "pi-subagents";
    version = "0.23.0";
    src = piSubagentsSrc;

    npmDepsHash = "sha256-hJwe6crzgVnosyJcfV5BIu0cfm69kEQ1vaZNteQxoY4=";

    dontNpmBuild = true;
  };

  superpowersSrc = pkgs.fetchgit {
    url = "https://github.com/obra/superpowers.git";
    rev = "e7a2d16476bf042e9add4699c9d018a90f86e4a6";
    sha256 = "sha256-8/M/S0BUYurZkFqe6LemVtBQnPSxBNfy1C7Q6f92hjE=";
  };

  # Diff npm package for multi-edit extension
  diffPackageSrc = pkgs.fetchurl {
    url = "https://registry.npmjs.org/diff/-/diff-7.0.0.tgz";
    sha256 = "sha256-kRLnmAa9a+V4p6bxJNlnEdQGCwus1NS6xOlq59CPKsE=";
  };

  diffPackage = pkgs.runCommand "diff-npm" { } ''
    mkdir -p $out/lib/node_modules/diff
    cd $out/lib/node_modules/diff
    ${pkgs.gnutar}/bin/tar -xzf ${diffPackageSrc} --strip-components=1
  '';

  piSettings = (builtins.fromJSON (builtins.readFile ./settings.json)) // {
    theme = "stylix";
    packages = [
      "${piListen}"
      "${piSubagents}/lib/node_modules/pi-subagents"
      "${superpowersSrc}"
    ];
  };

  stylixPiTheme = import ./theme.nix { inherit config; };

  package = pkgs.runCommand "pi-agent-files" { } ''
    mkdir -p \
      $out/.pi/agent/agent-teams \
      $out/.pi/agent/agents \
      $out/.pi/agent/extensions \
      $out/.pi/agent/node_modules \
      $out/.pi/agent/skills \
      $out/.pi/agent/themes

    cp -r ${./agent-teams}/. $out/.pi/agent/agent-teams/
    cp -r ${./agents}/. $out/.pi/agent/agents/
    cp -r ${./extensions}/. $out/.pi/agent/extensions/
    cp -r ${./skills}/. $out/.pi/agent/skills/

    ln -s ${config.home.homeDirectory}/projects/pi/extensions/pi-intervals $out/.pi/agent/extensions/pi-intervals
    ln -s ${config.home.homeDirectory}/projects/pi/extensions/pi-intervals/skills/intervals-time-entries $out/.pi/agent/skills/intervals-time-entries
    ln -s ${diffPackage}/lib/node_modules/diff $out/.pi/agent/node_modules/diff

    printf '%s' ${pkgs.lib.escapeShellArg (builtins.toJSON piSettings)} > $out/.pi/agent/settings.json
    printf '%s' ${pkgs.lib.escapeShellArg (builtins.toJSON stylixPiTheme)} > $out/.pi/agent/themes/stylix.json
  '';
in
{
  inherit
    package
    piSettings
    stylixPiTheme
    diffPackage
    notionCli
    ;
}
