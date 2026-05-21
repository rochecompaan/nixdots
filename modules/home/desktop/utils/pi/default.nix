{
  config,
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
      extensions = [
        "${config.home.homeDirectory}/projects/pi/extensions/pi-intervals"
      ];
      defaultModel = "gpt-5.5";
      defaultThinkingLevel = "high";
    };
  };
}
