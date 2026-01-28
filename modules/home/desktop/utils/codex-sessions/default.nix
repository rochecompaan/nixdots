{
  pkgs,
  ...
}:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "codex-sessions";
      runtimeInputs = [
        pkgs.fzf
        (pkgs.python3.withPackages (ps: [ ps.rich ]))
      ];
      text =
        let
          script = pkgs.writeText "codex-sessions.py" (builtins.readFile ./codex-sessions.py);
        in
        ''
          python ${script}
        '';
    })
  ];
}
