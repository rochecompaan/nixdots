{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  homeDir = config.home.homeDirectory;
  jail = inputs.jail-nix.lib.init pkgs;
  piFiles = import ../pi/files.nix {
    inherit config pkgs;
  };

  commonPkgsBase = with pkgs; [
    bashInteractive
    coreutils
    curl
    diffutils
    findutils
    gawkInteractive
    gnugrep
    gnused
    gnutar
    gzip
    jq
    procps
    ripgrep
    unzip
    wget
    which
  ];

  gitSupportDirs = [
    "${homeDir}/.config/git"
    "${homeDir}/.gnupg"
    "/run/user/1000/gnupg"
  ];

  gitSupportPkgs = with pkgs; [
    gnupg
    pinentry-gtk2
  ];

  editorDefault = config.home.sessionVariables.EDITOR or "vi";
  editorCommand = if editorDefault == "nvim" then "${pkgs.neovim}/bin/nvim" else editorDefault;

  commonJailOptions = with jail.combinators; [
    network
    time-zone
    no-new-session
    mount-cwd
  ];

  makeJailedAgent =
    {
      name,
      package,
      configDirs ? [ ],
      readonlyDirs ? [ ],
      extraPkgs ? [ ],
      gitPackage ? pkgs.git,
      gitSupport ? false,
      extraEnv ? { },
    }:
    let
      basePackage = jail name package (
        with jail.combinators;
        commonJailOptions
        ++ map (dir: readwrite (noescape dir)) (configDirs ++ lib.optionals gitSupport gitSupportDirs)
        ++ map (dir: readonly (noescape dir)) readonlyDirs
        ++ [
          (add-pkg-deps (
            commonPkgsBase ++ [ gitPackage ] ++ extraPkgs ++ lib.optionals gitSupport gitSupportPkgs
          ))
        ]
      );

      extraEnvFlags = lib.concatStringsSep " " (
        lib.mapAttrsToList (envName: envValue: "--setenv ${envName} \"${envValue}\"") extraEnv
      );
    in
    if extraEnvFlags == "" then
      basePackage
    else
      pkgs.runCommand name { } ''
        mkdir -p $out
        cp -a ${basePackage}/. $out/
        chmod u+w $out/bin/${name}
        substituteInPlace $out/bin/${name} \
          --replace '--setenv HOME "$HOME"' '--setenv HOME "$HOME" ${extraEnvFlags}'
      '';

  agentPkgs = inputs.llm-agents.packages.${pkgs.system};

  jailedPiGit = pkgs.writeShellScriptBin "git" ''
    exec ${pkgs.git}/bin/git \
      -c user.name='Roché Compaan' \
      -c user.email='roche@sixfeetup.com' \
      -c commit.gpgsign=true \
      -c tag.gpgsign=true \
      -c user.signingkey='0EFBE04F978347E4' \
      -c gpg.format=openpgp \
      -c gpg.openpgp.program='${pkgs.gnupg}/bin/gpg' \
      "$@"
  '';

  jailedPiPackage = pkgs.symlinkJoin {
    name = "pi-jailed-runtime";
    paths = [ agentPkgs.pi ];
    postBuild = ''
      mv $out/bin/pi $out/bin/.pi-real
      cat > $out/bin/pi <<EOF
      #!${pkgs.bashInteractive}/bin/bash
      export PI_CODING_AGENT_DIR=${homeDir}/.pi/agent-jailed
      export OPENROUTER_API_KEY="\$(cat ${config.sops.secrets."openrouter-api-key".path})"
      exec $out/bin/.pi-real "\$@"
      EOF
      chmod +x $out/bin/pi
    '';
    meta.mainProgram = "pi";
  };
in
{
  sops.secrets."openrouter-api-key" = {
    sopsFile = "${inputs.nix-secrets}/secrets.yaml";
  };
  home.activation.jailedPiAgentDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    agent_dir=${homeDir}/.pi/agent-jailed

    mkdir -p ${homeDir}/.pi/agent/sessions
    touch ${homeDir}/.pi/agent/auth.json

    rm -rf "$agent_dir"
    mkdir -p "$agent_dir"

    ln -sfn ${piFiles.package}/.pi/agent/settings.json "$agent_dir/settings.json"
    ln -sfn ${piFiles.package}/.pi/agent/extensions "$agent_dir/extensions"
    ln -sfn ${piFiles.package}/.pi/agent/skills "$agent_dir/skills"
    ln -sfn ${piFiles.package}/.pi/agent/themes "$agent_dir/themes"
    ln -sfn ${homeDir}/.pi/agent/auth.json "$agent_dir/auth.json"
    ln -sfn ${homeDir}/.pi/agent/sessions "$agent_dir/sessions"
  '';
  home.packages = [
    (makeJailedAgent {
      name = "jailed-claude";
      package = agentPkgs.claude-code;
      configDirs = [
        "~/.config/claude"
        "~/.local/share/claude"
        "~/.local/state/claude"
      ];
    })
    (makeJailedAgent {
      name = "jailed-codex";
      package = agentPkgs.codex;
      configDirs = [
        "~/.config/codex"
        "~/.local/share/codex"
        "~/.local/state/codex"
        "~/.codex"
      ];
    })
    (makeJailedAgent {
      name = "jailed-pi";
      package = jailedPiPackage;
      configDirs = [
        "${homeDir}/.pi/agent"
        "${homeDir}/.pi/agent/auth.json"
        "${homeDir}/.pi/agent/sessions"
        "${homeDir}/.pi/agent-jailed"
      ];
      readonlyDirs = [
        piFiles.package
        config.sops.secrets."openrouter-api-key".path
      ];
      extraPkgs = [ pkgs.neovim ];
      gitPackage = jailedPiGit;
      gitSupport = true;
      extraEnv = {
        DBUS_SESSION_BUS_ADDRESS = "\${DBUS_SESSION_BUS_ADDRESS:-}";
        DISPLAY = "\${DISPLAY:-:0}";
        EDITOR = "${editorCommand}";
        GIT_EDITOR = "${editorCommand}";
        VISUAL = "${editorCommand}";
        WAYLAND_DISPLAY = "\${WAYLAND_DISPLAY:-}";
        XAUTHORITY = "\${XAUTHORITY:-}";
        XDG_RUNTIME_DIR = "\${XDG_RUNTIME_DIR:-}";
      };
    })
  ];
}
