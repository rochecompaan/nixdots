{
  inputs,
  ...
}:
{
  imports = [ inputs.roche-pi.homeModules.default ];

  programs.roche-pi = {
    enable = true;
    stylix.enable = true;

    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-5.5";
      defaultThinkingLevel = "high";
    };
  };
}
