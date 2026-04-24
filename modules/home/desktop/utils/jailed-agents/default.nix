{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  homeDir = config.home.homeDirectory;
  gitUserName = config.programs.git.settings.user.name;
  gitUserEmail = config.programs.git.settings.user.email;
  jail = inputs.jail-nix.lib.extend {
    inherit pkgs;
    additionalCombinators =
      combinators: with combinators; {
        git-identity-env = compose [
          (set-env "GIT_CONFIG_COUNT" "2")
          (set-env "GIT_CONFIG_KEY_0" "user.name")
          (set-env "GIT_CONFIG_VALUE_0" gitUserName)
          (set-env "GIT_CONFIG_KEY_1" "user.email")
          (set-env "GIT_CONFIG_VALUE_1" gitUserEmail)
        ];
      };
  };
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
    pre-commit
    procps
    ripgrep
    unzip
    wget
    which
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
      gitSupport ? false,
      extraPermissions ? [ ],
    }:
    jail name package (
      with jail.combinators;
      commonJailOptions
      ++ map (dir: readwrite (noescape dir)) configDirs
      ++ map (dir: readonly (noescape dir)) readonlyDirs
      ++ lib.optionals gitSupport [ git-identity-env ]
      ++ extraPermissions
      ++ [ (add-pkg-deps (commonPkgsBase ++ [ pkgs.git ] ++ extraPkgs)) ]
    );

  agentPkgs = inputs.llm-agents.packages.${pkgs.system};

  jailedPiPackage = pkgs.symlinkJoin {
    name = "pi-jailed-runtime";
    paths = [ agentPkgs.pi ];
    postBuild = ''
      mv $out/bin/pi $out/bin/.pi-real
      cat > $out/bin/pi <<EOF
      #!${pkgs.bashInteractive}/bin/bash
      export EDITOR="${editorCommand}"
      export GIT_EDITOR="${editorCommand}"
      export VISUAL="${editorCommand}"
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
      gitSupport = true;
    })
  ];
}
