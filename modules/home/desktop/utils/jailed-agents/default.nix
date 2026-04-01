{
  inputs,
  pkgs,
  ...
}:
let
  jail = inputs.jail-nix.lib.init pkgs;

  commonPkgs = with pkgs; [
    bashInteractive
    coreutils
    curl
    diffutils
    findutils
    gawkInteractive
    git
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
      extraPkgs ? [ ],
    }:
    jail name package (
      with jail.combinators;
      commonJailOptions
      ++ map (dir: readwrite (noescape dir)) configDirs
      ++ [
        (add-pkg-deps commonPkgs)
        (add-pkg-deps extraPkgs)
      ]
    );

  agentPkgs = inputs.llm-agents.packages.${pkgs.system};
in
{
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
      package = agentPkgs.pi;
      configDirs = [
        "~/.config/pi"
        "~/.local/share/pi"
        "~/.local/state/pi"
      ];
    })
  ];
}
