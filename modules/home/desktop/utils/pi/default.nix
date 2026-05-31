{
  inputs,
  pkgs,
  ...
}:
{
  imports = [ inputs.roche-pi.homeModules.default ];

  programs.roche-pi = {
    enable = true;
    stylix.enable = true;

    settings = {
      agentHomeDir = "~/.pi/agent";
      defaultProvider = "openai-codex";
      defaultModel = "gpt-5.5";
      defaultThinkingLevel = "high";
    };
  };

  home.packages = [
    inputs.roche-pi.packages.${pkgs.system}.pi-local-auth
  ];
}
